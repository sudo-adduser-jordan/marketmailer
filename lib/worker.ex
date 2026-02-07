defmodule Marketmailer.PageWorker do
	@moduledoc false
	use GenServer, restart: :transient

	require Logger

	@ping_interval 10_000

	def start_link({mgr, id, page}),
		do:
			GenServer.start_link(__MODULE__, {mgr, id, page},
				name: {:via, Registry, {Marketmailer.Registry, {:page, id, page}}}
			)

	@impl true
	def init({mgr, id, page}) do
		send(self(), :work)
		{:ok, %{mgr: mgr, id: id, page: page, errors: 0}}
	end

	@impl true
	def handle_info(:work, state) do
		if Marketmailer.ESI.maintenance_active?() do
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
		%{mgr: mgr, id: id, page: page, errors: errs} = state
		Marketmailer.ESI.wait_for_error_window()

		case Marketmailer.ESI.fetch(id, page) do
			{:ok, data, ctx} ->
				# Logger.info("200 #{id} #{length(data)} \t #{format_ttl(ctx.ttl)} \t #{ctx.url}")
				Marketmailer.Database.upsert_orders(data)
				Marketmailer.Database.upsert_etag(ctx.url, ctx.etag)
				new_state = notify_and_reschedule(mgr, ctx.pages, ctx.ttl, %{state | errors: 0})
				{:noreply, new_state}

			{:not_modified, ctx} ->
				# Logger.info("304 #{id}     \t #{format_ttl(ctx.ttl)} \t #{ctx.url}")
				Marketmailer.Database.upsert_etag(ctx.url, ctx.etag)
				new_state = notify_and_reschedule(mgr, ctx.pages, ctx.ttl, %{state | errors: 0})
				{:noreply, new_state}

			{:error, :service_unavailable, ctx} ->
				Logger.info("503 #{id}     \t #{ctx.url}")
				schedule_next(@ping_interval)
				{:noreply, state}

			{:error, reason} ->
				delay = backoff_ms(errs)
				schedule_next(delay)

				Logger.warning("Fetch error for region #{id} page #{page}: #{inspect(reason)}; retry in #{div(delay, 1000)}s")

				{:noreply, %{state | errors: errs + 1}}
		end
	end

	defp try_claim_ping do
		# only one process 'wins' the right to ping during this 10s window.
		now = System.system_time(:millisecond)

		case :ets.lookup(:esi_error_state, :maintenance_mode) do
			[{:maintenance_mode, t}] when t > now ->
				false

			_ ->
				:ets.insert(:esi_error_state, {:maintenance_mode, now + @ping_interval})
				true
		end
	end

	defp notify_and_reschedule(mgr, count, ttl, state) do
		send(mgr, {:update_page_count, count})
		schedule_next(ttl)
		state
	end

	defp schedule_next(ms), do: Process.send_after(self(), :work, ms)
	defp backoff_ms(errors), do: (60_000 * :math.pow(2, errors)) |> round() |> min(300_000)

	defp format_ttl(ttl_ms) do
		total_seconds = div(ttl_ms, 1_000)
		minutes = div(total_seconds, 60)
		seconds = rem(total_seconds, 60)

		min = String.pad_leading("#{minutes}", 2, "0")
		sec = String.pad_leading("#{seconds}", 2, "0")

		"#{min}:#{sec}"
	end
end
