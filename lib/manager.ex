defmodule Marketmailer.RegionManager do
	@moduledoc false
	use GenServer, restart: :permanent

	@default_cycle_timeout 6 * 60_000

	def start_link(id, opts \\ []) when is_integer(id) and is_list(opts) do
		GenServer.start_link(__MODULE__, {id, opts}, name: via(id))
	end

	defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

	def subscribe(region, pid \\ self()) when is_integer(region) do
		GenServer.call(via(region), {:subscribe, pid})
	end

	def page_started(region, page) when is_integer(region) and is_integer(page) do
		GenServer.cast(via(region), {:page_started, page})
	end

	def page_count(region, count) when is_integer(region) and is_integer(count) do
		GenServer.cast(via(region), {:update_page_count, count})
	end

	def page_result(region, page, status, context \\ %{})
			when is_integer(region) and is_integer(page) and is_atom(status) do
		GenServer.cast(via(region), {:page_result, page, status, context})
	end

	@impl true
	def init({id, opts}) do
		timeout = Keyword.get(opts, :cycle_timeout, @default_cycle_timeout)
		pages = [1 | Etag.Database.pages_for_region(id)] |> Enum.uniq()
		Enum.each(pages, &start_page(id, &1))

		listeners =
			case Process.whereis(Discord.Broadcaster) do
				nil -> MapSet.new()
				pid -> MapSet.new([pid])
			end

		{:ok,
		 %{
			 id: id,
			 page_count: Enum.max(pages),
			 cycle_id: nil,
			 started: MapSet.new(),
			 results: %{},
			 expected_pages: nil,
			 timer: nil,
			 listeners: listeners,
			 cycle_timeout: timeout
		 }}
	end

	@impl true
	def handle_call({:subscribe, pid}, _from, state) do
		{:reply, :ok, %{state | listeners: MapSet.put(state.listeners, pid)}}
	end

	@impl true
	def handle_cast({:page_started, page}, state) do
		state =
			if is_nil(state.cycle_id) do
				%{state | cycle_id: System.unique_integer([:positive, :monotonic])}
			else
				state
			end

		state = %{state | started: MapSet.put(state.started, page)}

		state =
			if Map.has_key?(state.results, page) do
				%{state | results: Map.delete(state.results, page)}
			else
				state
			end

		{:noreply, refresh_timer(state)}
	end

	@impl true
	def handle_cast({:update_page_count, count}, state) do
		count = max(count, 1)
		handle_page_count(count, state)
	end

	@impl true
	def handle_cast({:page_result, page, status, context}, state) do
		if MapSet.member?(state.started, page) do
			expected_pages = expected_pages(context, state.expected_pages)
			result = %{status: status, reason: Map.get(context, :reason)}
			state = %{state | expected_pages: expected_pages, results: Map.put(state.results, page, result)}

			case check_cycle(state) do
				{:completed, event, state} -> {:noreply, emit(state, event)}
				{:pending, state} -> {:noreply, state}
			end
		else
			{:noreply, state}
		end
	end

	@impl true
	def handle_info({:cycle_timeout, timer_token}, state) do
		case state.timer do
			{^timer_token, _timer_handle} ->
				failures = pending_failures(state)

				failure = %{
					region: state.id,
					cycle_id: state.cycle_id,
					pages: state.expected_pages,
					failures: failures,
					updated_pages: updated_pages(state.results)
				}

				log_failure(state.id, failure)
				{:noreply, state |> new_cycle() |> emit({:region_refresh_failed, failure})}

			_ ->
				{:noreply, state}
		end
	end

	def handle_info(_message, state), do: {:noreply, state}

	defp handle_page_count(count, state) do
		state = set_expected_pages(state, count)

		state =
			case check_cycle(state) do
				{:completed, event, state} -> emit(state, event)
				{:pending, state} -> state
			end

		if count == state.page_count do
			{:noreply, state}
		else
			Marketmailer.Log.info(
				"page_count_changed",
				%{region: state.id, old: state.page_count, new: count},
				"Region #{state.id}: pages #{state.page_count} -> #{count}"
			)

			adjust_workers(state.id, state.page_count, count)
			{:noreply, %{state | page_count: count}}
		end
	end

	defp new_cycle(state) do
		%{state | cycle_id: nil, started: MapSet.new(), results: %{}, timer: nil}
	end

	defp set_expected_pages(%{expected_pages: previous} = state, count) when is_integer(previous) and previous > count do
		started = MapSet.filter(state.started, &(&1 <= count))
		results = Map.filter(state.results, fn {page, _result} -> page <= count end)
		%{state | expected_pages: count, started: started, results: results}
	end

	defp set_expected_pages(state, count), do: %{state | expected_pages: count}

	defp expected_pages(%{pages: pages}, _current) when is_integer(pages) and pages > 0, do: pages
	defp expected_pages(_context, current), do: current

	defp check_cycle(%{expected_pages: nil} = state), do: {:pending, state}

	defp check_cycle(state) do
		expected_pages = state.expected_pages

		if complete?(expected_pages, state.results) do
			cancel_timer(state)
			statuses = Enum.map(state.results, fn {_page, result} -> result.status end)
			failures = failures(state.results)

			event =
				cond do
					failures != [] ->
						failure = %{
							region: state.id,
							cycle_id: state.cycle_id,
							pages: expected_pages,
							failures: failures,
							updated_pages: updated_pages(state.results)
						}

						log_failure(state.id, failure)
						{:region_refresh_failed, failure}

					:updated in statuses ->
						summary = %{
							region: state.id,
							cycle_id: state.cycle_id,
							pages: expected_pages,
							updated_pages: updated_pages(state.results)
						}

						Marketmailer.Log.info(
							"region_refresh_complete",
							summary,
							"Region #{state.id} refresh complete"
						)

						{:region_refresh_complete, summary}

					true ->
						summary = %{
							region: state.id,
							cycle_id: state.cycle_id,
							pages: expected_pages,
							updated_pages: []
						}

						Marketmailer.Log.info(
							"region_refresh_unchanged",
							summary,
							"Region #{state.id} refresh unchanged"
						)

						{:region_refresh_unchanged, summary}
				end

			{:completed, event, new_cycle(%{state | expected_pages: expected_pages})}
		else
			{:pending, refresh_timer(state)}
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
		pages = for {page, %{status: :updated}} <- results, do: page
		Enum.sort(pages)
	end

	defp refresh_timer(%{timer: nil} = state), do: schedule_timer(state)

	defp refresh_timer(state) do
		cancel_timer(state)
		schedule_timer(%{state | timer: nil})
	end

	defp schedule_timer(state) do
		timer_token = make_ref()
		timer_handle = Process.send_after(self(), {:cycle_timeout, timer_token}, state.cycle_timeout)
		%{state | timer: {timer_token, timer_handle}}
	end

	defp pending_failures(%{expected_pages: nil}), do: [%{page: nil, reason: :cycle_timeout}]

	defp pending_failures(%{expected_pages: expected, results: results}) when is_integer(expected) and expected > 0 do
		pending = for page <- 1..expected//1, not Map.has_key?(results, page), do: page

		case pending do
			[] -> [%{page: nil, reason: :cycle_timeout}]
			pages -> Enum.map(pages, &%{page: &1, reason: :cycle_timeout})
		end
	end

	defp cancel_timer(%{timer: nil}), do: :ok

	defp cancel_timer(%{timer: {_timer_token, timer_handle}}) do
		Process.cancel_timer(timer_handle)
		:ok
	end

	defp emit(state, {event, payload}) do
		Enum.each(state.listeners, &send(&1, {event, payload}))
		state
	end

	defp log_failure(region, %{pages: pages, failures: failures}) do
		Marketmailer.Log.warning(
			"region_refresh_failed",
			%{region: region, pages: pages, failures: failures},
			"Region #{region} refresh failed"
		)
	end

	defp adjust_workers(id, old, new) do
		cond do
			new > old -> Enum.each((old + 1)..new, &start_page(id, &1))
			new < old -> Enum.each((new + 1)..old, &stop_page(id, &1))
			true -> :ok
		end
	end

	defp start_page(id, page) do
		case Registry.lookup(Marketmailer.Registry, {:page, id, page}) do
			[] ->
				DynamicSupervisor.start_child(
					Marketmailer.PageSup,
					{Marketmailer.PageWorker, {self(), id, page}}
				)

			_ ->
				:ok
		end
	end

	defp stop_page(id, page) do
		for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, id, page}),
				do: GenServer.stop(pid, :normal)
	end
end
