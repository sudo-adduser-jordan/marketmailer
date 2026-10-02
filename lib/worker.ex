defmodule Marketmailer.PageWorker do
	# One worker per page: each page URL has its own ESI ETag/Expires, so an
	# unchanged page stays a cheap 304 on its own TTL while a changed page
	# refreshes promptly — a sequential 1..N sweep would re-pay every page
	# each cycle and head-of-line block the changed one.
	use GenServer, restart: :transient

	@ping_interval 10_000

	def start_link({manager, id, page}) do
		GenServer.start_link(__MODULE__, {manager, id, page},
			name: {:via, Registry, {Marketmailer.Registry, {:page, id, page}}}
		)
	end

	@impl true
	def init({manager, id, page}) do
		# Crash resume: delay first fetch until the persisted Expires passes.
		# Unexpected entries (missing/expired/corrupt) fetch immediately with a
		# tiny stagger so a cold boot does not fire every page in the same ms.
		delay =
			case Etag.Database.resume_delay_ms(ESI.page_url(id, page)) do
				0 -> :erlang.phash2({id, page}, 500)
				remaining -> remaining + :erlang.phash2({id, page}, 2_000)
			end

		Process.send_after(self(), :work, delay)
		{:ok, %{manager: manager, id: id, page: page, errors: 0}}
	end

	@impl true
	def handle_info(:work, state) do
		if ESI.maintenance_active?() do
			# Global maintenance is on. Try to extend the timer to "claim" the next 10s slot.
			if try_claim_ping() do
				perform_fetch(state)
			else
				# Another worker is already the designated pinger or waiting
				schedule_next(@ping_interval)
				{:noreply, state}
			end
		else
			perform_fetch(state)
		end
	end

	defp perform_fetch(state) do
		%{manager: manager, id: id, page: page, errors: errs} = state
		ESI.wait_for_error_window()
		Market.UpdateCoordinator.page_started(id, page)

		case ESI.fetch(id, page) do
			{:ok, data, ctx} ->
				Marketmailer.Log.info(
					"page_fetch_ok",
					%{
						region: id,
						page: page,
						status: 200,
						orders: length(data),
						ttl_ms: ctx.ttl,
						url: ctx.url
					},
					"200 #{id} #{length(data)} \t #{format_ttl(ctx.ttl)} \t #{ctx.url}"
				)

				case persist_orders(data, ctx) do
					:ok ->
						Market.UpdateCoordinator.page_result(id, page, :updated, %{pages: ctx.pages})

					{:error, reason} ->
						Market.UpdateCoordinator.page_result(id, page, :failed, %{reason: reason})
				end

				new_state = notify_and_reschedule(manager, ctx.pages, ctx.ttl, %{state | errors: 0})
				{:noreply, new_state}

			{:not_modified, ctx} ->
				Marketmailer.Log.info(
					"page_fetch_not_modified",
					%{
						region: id,
						page: page,
						status: 304,
						ttl_ms: ctx.ttl,
						url: ctx.url
					},
					"304 #{id}     \t #{format_ttl(ctx.ttl)} \t #{ctx.url}"
				)

				case safe_upsert_etag(ctx) do
					:ok ->
						Market.UpdateCoordinator.page_result(id, page, :not_modified, %{pages: ctx.pages})
						new_state = notify_and_reschedule(manager, ctx.pages, ctx.ttl, %{state | errors: 0})
						{:noreply, new_state}

					{:error, reason} ->
						Market.UpdateCoordinator.page_result(id, page, :failed, %{reason: reason})
						schedule_next(backoff_ms(state.errors, {id, page}))
						{:noreply, %{state | errors: state.errors + 1}}
				end

			{:error, :service_unavailable, ctx} ->
				Marketmailer.Log.info(
					"page_fetch_unavailable",
					%{
						region: id,
						page: page,
						status: 503,
						url: ctx.url
					},
					"503 #{id}     \t #{ctx.url}"
				)

				Market.UpdateCoordinator.page_result(id, page, :failed, %{reason: :service_unavailable})
				schedule_next(@ping_interval)
				{:noreply, state}

			{:error, :rate_limited, ctx} ->
				# 429: the server says when enough tokens are back; reschedule on
				# that instead of counting against the exponential backoff.
				Marketmailer.Log.warning(
					"page_fetch_rate_limited",
					%{
						region: id,
						page: page,
						status: 429,
						retry_after_ms: ctx.retry_after_ms,
						url: ctx.url
					},
					"429 #{id}     \t retry in #{format_ttl(ctx.retry_after_ms)} \t #{ctx.url}"
				)

				Market.UpdateCoordinator.page_result(id, page, :failed, %{reason: :rate_limited})
				schedule_next(max(ctx.retry_after_ms, 1_000))
				{:noreply, %{state | errors: 0}}

			{:error, reason} ->
				delay = backoff_ms(errs, {id, page})
				schedule_next(delay)

				Marketmailer.Log.warning(
					"page_fetch_error",
					%{
						region: id,
						page: page,
						reason: inspect(reason),
						retry_in_ms: delay
					},
					"Fetch error for region #{id} page #{page}: #{inspect(reason)}; retry in #{div(delay, 1000)}s"
				)

				Market.UpdateCoordinator.page_result(id, page, :failed, %{reason: failure_reason(reason)})
				{:noreply, %{state | errors: errs + 1}}
		end
	end

	# A DB crash must report :failed so the region cycle completes instead of
	# hanging on a page that started but never reports. Disk-full is an error
	# (not a warning) and skips the etag write so no further DB writes run.
	defp persist_orders(data, ctx) do
		case Market.Database.upsert_orders(data) do
			{:error, e} ->
				{:error, persist_failure_reason(e, ctx, length(data))}

			_count ->
				Etag.Database.upsert_etag(ctx.url, ctx.etag, Map.get(ctx, :expires_at))
				:ok
		end
	rescue
		e ->
			{:error, persist_failure_reason(e, ctx, length(data))}
	end

	defp persist_failure_reason(e, ctx, order_count) do
		if Market.DbWriter.disk_full?(e) do
			Marketmailer.Log.error(
				"disk_full",
				%{region: ctx |> Map.get(:url), reason: first_line(e), orders: order_count},
				"Disk full; skipping persist for #{ctx.url}"
			)

			:disk_full
		else
			Marketmailer.Log.warning(
				"page_persist_failed",
				%{region: ctx |> Map.get(:url), reason: first_line(e), orders: order_count},
				"Persist failed for #{ctx.url}"
			)

			:persist_failed
		end
	end

	# 304 path must not crash the GenServer when the pool is saturated:
	# a DBConnection queue_timeout here used to terminate the worker without
	# ever reporting to the UpdateCoordinator, stalling the region cycle.
	defp safe_upsert_etag(%{etag: nil}), do: :ok

	defp safe_upsert_etag(%{etag: false}), do: :ok

	defp safe_upsert_etag(ctx) do
		Etag.Database.upsert_etag(ctx.url, ctx.etag, Map.get(ctx, :expires_at))
		:ok
	rescue
		e ->
			if Market.DbWriter.disk_full?(e) do
				Marketmailer.Log.error(
					"disk_full",
					%{region: ctx |> Map.get(:url), reason: first_line(e)},
					"Disk full; skipping etag persist for #{ctx.url}"
				)

				{:error, :disk_full}
			else
				Marketmailer.Log.warning(
					"page_persist_failed",
					%{region: ctx |> Map.get(:url), reason: first_line(e)},
					"Persist failed for #{ctx.url}"
				)

				{:error, :persist_failed}
			end
	end

	# Exqlite embeds the full SQL statement in the exception message (a
	# 1000-row upsert is ~90KB) — keep only the first line ("Database busy")
	# so one failure cannot fill the error-log rotation with placeholders.
	defp first_line(e), do: e |> Exception.message() |> String.split("\n") |> List.first()

	# Transport-level failures (DNS, TCP reset, TLS close, timeouts, no
	# route to host) mean the pipe is down, not that ESI rejected us. Report
	# a stable :offline reason so coordinator logs stay greppable instead of
	# a different struct dump per HTTP client, and keep counting against the
	# exponential backoff so a dead link backs off to 5m instead of hammering
	# it once a minute from every page worker.
	defp failure_reason(%{reason: inner}) when is_atom(inner) do
		if inner in [:nxdomain, :econnrefused, :econnreset, :etimedout, :timeout, :closed, :ehostunreach, :enetunreach] do
			:offline
		else
			inner
		end
	end

	defp failure_reason(%{__exception__: true} = error) do
		module = error.__struct__ |> Module.split() |> List.last() |> String.downcase()

		if String.contains?(module, ["transport", "mint", "finch", "req", "http", "connection"]) or
				 Exception.message(error)
				 |> String.downcase()
				 |> String.contains?([
					 "nxdomain",
					 "network",
					 "connection",
					 "closed",
					 "timeout",
					 "unreachable",
					 "econnrefused",
					 "ehostunreach"
				 ]) do
			:offline
		else
			:unknown
		end
	end

	defp failure_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
	defp failure_reason(reason) when is_integer(reason), do: reason
	defp failure_reason(_reason), do: :unknown

	defp try_claim_ping do
		# only one process 'wins' the right to ping during this 10s window.
		now = System.system_time(:millisecond)

		case :ets.lookup(:esi_error_state, :maintenance_mode) do
			[{:maintenance_mode, time}] when time > now ->
				false

			_ ->
				:ets.insert(:esi_error_state, {:maintenance_mode, now + @ping_interval})
				true
		end
	end

	defp notify_and_reschedule(manager, count, ttl, state) do
		send(manager, {:update_page_count, count})
		schedule_next(ttl)
		state
	end

	defp schedule_next(ms), do: Process.send_after(self(), :work, ms)

	# Exponential backoff (1m, 2m, 4m, capped at 5m) plus per-page jitter so
	# every worker does not reconnect in the same millisecond when the link
	# or ESI comes back.
	defp backoff_ms(errors, jitter_key) do
		base = (60_000 * :math.pow(2, errors)) |> round() |> min(300_000)
		base + :erlang.phash2(jitter_key, 30_000)
	end

	def format_ttl(ttl_ms) do
		total_seconds = div(ttl_ms, 1_000)
		minutes = div(total_seconds, 60)
		seconds = rem(total_seconds, 60)

		min = String.pad_leading("#{minutes}", 2, "0")
		sec = String.pad_leading("#{seconds}", 2, "0")

		"#{min}:#{sec}"
	end
end
