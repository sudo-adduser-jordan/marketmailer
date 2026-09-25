defmodule Marketmailer.PageWorker do
	use GenServer, restart: :transient

	@ping_interval 10_000

	def start_link({manager, id, page}) do
		GenServer.start_link(__MODULE__, {manager, id, page},
			name: {:via, Registry, {Marketmailer.Registry, {:page, id, page}}}
		)
	end

	@impl true
	def init({manager, id, page}) do
		send(self(), :work)
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

				Market.Database.upsert_orders(data)
				Etag.Database.upsert_etag(ctx.url, ctx.etag)
				Market.UpdateCoordinator.page_result(id, page, :updated, %{pages: ctx.pages})
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

				if ctx.etag, do: Etag.Database.upsert_etag(ctx.url, ctx.etag)
				Market.UpdateCoordinator.page_result(id, page, :not_modified, %{pages: ctx.pages})
				new_state = notify_and_reschedule(manager, ctx.pages, ctx.ttl, %{state | errors: 0})
				{:noreply, new_state}

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
				delay = backoff_ms(errs)
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
	defp backoff_ms(errors), do: (60_000 * :math.pow(2, errors)) |> round() |> min(300_000)

	def format_ttl(ttl_ms) do
		total_seconds = div(ttl_ms, 1_000)
		minutes = div(total_seconds, 60)
		seconds = rem(total_seconds, 60)

		min = String.pad_leading("#{minutes}", 2, "0")
		sec = String.pad_leading("#{seconds}", 2, "0")

		"#{min}:#{sec}"
	end
end
