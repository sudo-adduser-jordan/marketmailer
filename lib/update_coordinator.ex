defmodule Market.UpdateCoordinator do
	@moduledoc """
	Coordinates page-worker results into completed region refresh cycles.
	"""

	use GenServer

	@default_cycle_timeout 10 * 60_000

	def start_link(opts \\ []) do
		name = Keyword.get(opts, :name, __MODULE__)
		GenServer.start_link(__MODULE__, opts, name: name)
	end

	def subscribe(pid \\ self(), server \\ __MODULE__) do
		GenServer.call(server, {:subscribe, pid})
	end

	def page_started(region, page, server \\ __MODULE__) when is_integer(region) and is_integer(page) do
		GenServer.cast(server, {:page_started, region, page})
	end

	def page_count(region, count, server \\ __MODULE__) when is_integer(region) and is_integer(count) do
		GenServer.cast(server, {:page_count, region, count})
	end

	def page_result(region, page, status, context \\ %{}, server \\ __MODULE__)
			when is_integer(region) and is_integer(page) and is_atom(status) do
		GenServer.cast(server, {:page_result, region, page, status, context})
	end

	@impl true
	def init(opts) do
		timeout = Keyword.get(opts, :cycle_timeout, @default_cycle_timeout)

		{:ok, %{regions: %{}, listeners: MapSet.new(), cycle_timeout: timeout}}
	end

	@impl true
	def handle_call({:subscribe, pid}, _from, state) do
		{:reply, :ok, %{state | listeners: MapSet.put(state.listeners, pid)}}
	end

	@impl true
	def handle_cast({:page_started, region, page}, state) do
		region_state = get_region(state, region)
		region_state = %{region_state | started: MapSet.put(region_state.started, page)}

		region_state =
			if Map.has_key?(region_state.results, page) do
				%{region_state | results: Map.delete(region_state.results, page)}
			else
				region_state
			end

		region_state = schedule_timer(region, region_state, state.cycle_timeout)
		{:noreply, put_region(state, region, region_state)}
	end

	@impl true
	def handle_cast({:page_count, region, count}, state) when count > 0 do
		region_state = get_region(state, region)
		region_state = set_expected_pages(region_state, count)
		{event, region_state} = maybe_complete(region, region_state, state.cycle_timeout)
		{:noreply, state |> put_region(region, region_state) |> emit(event)}
	end

	@impl true
	def handle_cast({:page_result, region, page, status, context}, state) do
		region_state = get_region(state, region)

		if MapSet.member?(region_state.started, page) do
			expected_pages = expected_pages(context, region_state.expected_pages)

			result = %{
				status: status,
				reason: Map.get(context, :reason)
			}

			region_state = %{
				region_state
				| expected_pages: expected_pages,
					results: Map.put(region_state.results, page, result)
			}

			{event, region_state} = maybe_complete(region, region_state, state.cycle_timeout)
			{:noreply, state |> put_region(region, region_state) |> emit(event)}
		else
			{:noreply, state}
		end
	end

	@impl true
	def handle_info({:cycle_timeout, region, timer_token}, state) do
		case Map.get(state.regions, region) do
			%{timer: {^timer_token, _timer_handle}} = region_state ->
				failure = %{
					region: region,
					pages: region_state.expected_pages,
					failures: [%{page: nil, reason: :cycle_timeout}]
				}

				log_failure(failure)
				Enum.each(state.listeners, &send(&1, {:region_refresh_failed, failure}))
				{:noreply, put_region(state, region, new_cycle(region_state.expected_pages))}

			_ ->
				{:noreply, state}
		end
	end

	def handle_info(_message, state), do: {:noreply, state}

	defp get_region(state, region) do
		Map.get_lazy(state.regions, region, fn -> new_cycle(nil) end)
	end

	defp put_region(state, region, region_state) do
		%{state | regions: Map.put(state.regions, region, region_state)}
	end

	defp new_cycle(expected_pages) do
		%{expected_pages: expected_pages, started: MapSet.new(), results: %{}, timer: nil}
	end

	defp set_expected_pages(%{expected_pages: previous} = region_state, count)
			 when is_integer(previous) and previous > count do
		started = MapSet.filter(region_state.started, &(&1 <= count))
		results = Map.filter(region_state.results, fn {page, _result} -> page <= count end)
		%{region_state | expected_pages: count, started: started, results: results}
	end

	defp set_expected_pages(region_state, count), do: %{region_state | expected_pages: count}

	defp expected_pages(%{pages: pages}, _current) when is_integer(pages) and pages > 0, do: pages
	defp expected_pages(_context, current), do: current

	defp maybe_complete(_region, %{expected_pages: nil} = region_state, _timeout), do: {nil, region_state}

	defp maybe_complete(region, region_state, timeout) do
		expected_pages = region_state.expected_pages

		if complete?(expected_pages, region_state.results) do
			cancel_timer(region_state)
			statuses = Enum.map(region_state.results, fn {_page, result} -> result.status end)
			failures = failures(region_state.results)

			event =
				cond do
					failures != [] ->
						failure = %{
							region: region,
							pages: expected_pages,
							failures: failures
						}

						log_failure(failure)
						{:region_refresh_failed, failure}

					:updated in statuses ->
						summary = %{
							region: region,
							pages: expected_pages,
							updated_pages: updated_pages(region_state.results)
						}

						Marketmailer.Log.info(
							"region_refresh_complete",
							summary,
							"Region #{region} refresh complete"
						)

						{:region_refresh_complete, summary}

					true ->
						nil
				end

			{event, new_cycle(expected_pages)}
		else
			{nil, schedule_timer(region, region_state, timeout)}
		end
	end

	defp complete?(expected_pages, results) when is_integer(expected_pages) and expected_pages > 0 do
		Enum.all?(1..expected_pages, &Map.has_key?(results, &1))
	end

	defp complete?(_expected_pages, _results), do: false

	defp failures(results) do
		for {page, %{status: :failed, reason: reason}} <- results,
				do: %{page: page, reason: reason}
	end

	defp updated_pages(results) do
		for {page, %{status: :updated}} <- results, do: page
	end

	defp schedule_timer(region, %{timer: nil} = region_state, timeout) do
		timer_token = make_ref()
		timer_handle = Process.send_after(self(), {:cycle_timeout, region, timer_token}, timeout)
		%{region_state | timer: {timer_token, timer_handle}}
	end

	defp schedule_timer(_region, region_state, _timeout), do: region_state

	defp cancel_timer(%{timer: nil}), do: :ok

	defp cancel_timer(%{timer: {_timer_token, timer_handle}}) do
		Process.cancel_timer(timer_handle)
		:ok
	end

	defp emit(state, nil), do: state

	defp emit(state, {event, payload}) do
		Enum.each(state.listeners, &send(&1, {event, payload}))
		state
	end

	defp log_failure(%{region: region, pages: pages, failures: failures}) do
		Marketmailer.Log.warning(
			"region_refresh_failed",
			%{region: region, pages: pages, failures: failures},
			"Region #{region} refresh failed"
		)
	end
end
