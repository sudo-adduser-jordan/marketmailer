defmodule Marketmailer.PageWorker do
	use GenServer, restart: :transient

	alias Marketmailer.Utils

	@ping_interval 10_000
	@gate_recheck_ms 5_000
	@start_jitter 30_000

	def start_link({manager, id, page}) do
		GenServer.start_link(__MODULE__, {manager, id, page},
			name: {:via, Registry, {Marketmailer.Registry, {:page, id, page}}}
		)
	end

	@impl true
	def init({_manager, id, page}) do
		delay = Etag.Database.resume_delay_ms(ESI.page_url(id, page)) + start_jitter_ms()
		Process.send_after(self(), :work, delay)
		{:ok, %{id: id, page: page, errors: 0}}
	end

	defp start_jitter_ms do
		case Application.get_env(:marketmailer, :poll_start_jitter_ms, @start_jitter) do
			max when is_integer(max) and max > 0 -> :rand.uniform(max)
			_ -> 0
		end
	end

	@impl true
	def handle_info(:work, state) do
		case fetch_gate(state.id, state.page) do
			:wait ->
				schedule_next(@gate_recheck_ms)
				{:noreply, state}

			:gone ->
				Marketmailer.RegionManager.page_result(state.id, state.page, :gone, %{reason: :not_found})

				Marketmailer.Log.info(
					"page_gone",
					%{region: state.id, page: state.page},
					"Region #{state.id} page #{state.page} no longer exists; stopping worker"
				)

				{:stop, :normal, state}

			:ok ->
				cond do
					Marketmailer.Maintenance.down?() ->
						schedule_next(Marketmailer.Maintenance.recheck_ms())
						{:noreply, state}

					ESI.maintenance_active?() and not try_claim_ping() ->
						schedule_next(@ping_interval)
						{:noreply, state}

					true ->
						perform_fetch(state)
				end
		end
	end

	defp backoff_ms(errors) do
		(60_000 * :math.pow(2, errors)) |> round() |> min(300_000)
	end

	defp fetch_gate(id, page) do
		Marketmailer.RegionManager.fetch_gate(id, page)
	catch
		:exit, _ -> :ok
	end

	defp perform_fetch(state) do
		%{id: id, page: page, errors: errs} = state
		ESI.wait_for_error_window()
		Marketmailer.RegionManager.page_started(id, page)

		case ESI.fetch(id, page) do
			{:ok, data, ctx} -> handle_ok(data, ctx, state)
			{:not_modified, ctx} -> handle_not_modified(ctx, state)
			{:error, :service_unavailable, ctx} -> handle_unavailable(ctx, state)
			{:error, :rate_limited, ctx} -> handle_rate_limited(ctx, state)
			{:error, :not_found, _ctx} -> stop_gone(state)
			{:error, reason} -> handle_error(reason, errs, state)
		end
	end

	defp handle_ok(data, ctx, state) do
		%{id: id, page: page} = state

		Marketmailer.Log.info(
			"page_fetch_ok",
			%{region: id, page: page, status: 200, orders: length(data), ttl_ms: ctx.ttl, url: ctx.url},
			"200 #{id} #{length(data)} \t #{Utils.format_ttl(ctx.ttl)} \t #{ctx.url}"
		)

		case persist_orders(data, ctx) do
			:ok ->
				Marketmailer.RegionManager.page_result(id, page, :updated, %{pages: ctx.pages})

			{:error, reason} ->
				Marketmailer.RegionManager.page_result(id, page, :failed, %{reason: reason})
		end

		{:noreply, notify_and_reschedule(id, ctx.pages, ctx.ttl, %{state | errors: 0})}
	end

	defp handle_not_modified(ctx, state) do
		%{id: id, page: page} = state

		Marketmailer.Log.info(
			"page_fetch_not_modified",
			%{region: id, page: page, status: 304, ttl_ms: ctx.ttl, url: ctx.url},
			"304 #{id}     \t #{Utils.format_ttl(ctx.ttl)} \t #{ctx.url}"
		)

		:ok = safe_upsert_etag(ctx)
		Marketmailer.RegionManager.page_result(id, page, :not_modified, %{pages: ctx.pages})
		{:noreply, notify_and_reschedule(id, ctx.pages, ctx.ttl, %{state | errors: 0})}
	end

	defp handle_unavailable(ctx, state) do
		%{id: id, page: page} = state

		Marketmailer.Log.info(
			"page_fetch_unavailable",
			%{region: id, page: page, status: 503, url: ctx.url},
			"5xx #{id}     \t #{ctx.url}"
		)

		Marketmailer.RegionManager.page_result(id, page, :failed, %{reason: :service_unavailable})
		schedule_next(@ping_interval)
		{:noreply, state}
	end

	defp handle_rate_limited(ctx, state) do
		%{id: id, page: page} = state

		Marketmailer.Log.warning(
			"page_fetch_rate_limited",
			%{region: id, page: page, status: 429, retry_after_ms: ctx.retry_after_ms, url: ctx.url},
			"429 #{id}     \t retry in #{Utils.format_ttl(ctx.retry_after_ms)} \t #{ctx.url}"
		)

		Marketmailer.RegionManager.page_result(id, page, :failed, %{reason: :rate_limited})
		schedule_next(max(ctx.retry_after_ms, 1_000))
		{:noreply, %{state | errors: 0}}
	end

	defp handle_error(reason, errs, state) do
		%{id: id, page: page} = state

		delay =
			if ESI.network_error?(reason) or pause_reason?(reason) do
				Marketmailer.Maintenance.recheck_ms()
			else
				backoff_ms(errs)
			end

		schedule_next(delay)

		Marketmailer.Log.warning(
			"page_fetch_error",
			%{region: id, page: page, reason: inspect(reason), retry_in_ms: delay},
			"Fetch error for region #{id} page #{page}: #{inspect(reason)}; retry in #{div(delay, 1000)}s"
		)

		Marketmailer.RegionManager.page_result(id, page, :failed, %{reason: failure_reason(reason)})
		{:noreply, %{state | errors: errs + 1}}
	end

	# A request that never got an answer (saturated pool, raised adapter) means
	# ESI is not serving: wait for the pause window instead of the long backoff.
	defp pause_reason?(%{reason: :request_failed}), do: true
	defp pause_reason?(_reason), do: false

	defp persist_orders(data, ctx) do
		case Market.Database.upsert_orders(data, ctx.url) do
			{:error, e} ->
				{:error, persist_failure_reason(e, ctx, length(data))}

			_count ->
				case Etag.Database.upsert_etag(ctx.url, ctx.etag, Map.get(ctx, :expires_at)) do
					:ok ->
						:ok

					{:error, e} ->
						Marketmailer.Log.warning(
							"etag_persist_failed",
							%{region: ctx.url, reason: first_line(e)},
							"Etag persist failed for #{ctx.url}"
						)

						:ok
				end
		end
	rescue
		e ->
			{:error, persist_failure_reason(e, ctx, length(data))}
	end

	defp persist_failure_reason(e, ctx, order_count) do
		if Database.Writer.disk_full?(e) do
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

	defp safe_upsert_etag(%{etag: nil}), do: :ok
	defp safe_upsert_etag(%{etag: false}), do: :ok

	defp safe_upsert_etag(ctx) do
		Etag.Database.touch_cache(ctx.url, ctx.etag, Map.get(ctx, :expires_at))
		:ok
	end

	defp first_line(e), do: e |> Exception.message() |> String.split("\n") |> List.first()

	defp failure_reason(reason) do
		if ESI.network_error?(reason), do: :offline, else: failure_label(reason)
	end

	defp failure_label(%{reason: inner}) when is_atom(inner), do: inner
	defp failure_label(%{__exception__: true}), do: :unknown
	defp failure_label(reason) when is_atom(reason) or is_binary(reason), do: reason
	defp failure_label(reason) when is_integer(reason), do: reason
	defp failure_label(_reason), do: :unknown

	defp try_claim_ping do
		now = System.system_time(:millisecond)

		case :ets.lookup(:esi_error_state, :maintenance_ping) do
			[{:maintenance_ping, time}] when time > now ->
				false

			_ ->
				:ets.insert(:esi_error_state, {:maintenance_ping, now + @ping_interval})
				true
		end
	end

	defp notify_and_reschedule(id, count, ttl, state) do
		Marketmailer.RegionManager.page_count(id, count)
		schedule_next(ttl)
		state
	end

	defp schedule_next(ms), do: Process.send_after(self(), :work, ms)

	defp stop_gone(state) do
		%{id: id, page: page} = state
		Marketmailer.RegionManager.page_result(id, page, :gone, %{reason: :not_found})

		Marketmailer.Log.warning(
			"page_fetch_not_found",
			%{region: id, page: page, reason: "404"},
			"Fetch 404 for region #{id} page #{page}: gate bypassed, stopping worker"
		)

		{:stop, :normal, state}
	end
end
