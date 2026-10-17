defmodule Marketmailer.RegionManager do
	@moduledoc false
	use GenServer, restart: :permanent

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

	def fetch_gate(region, page) when is_integer(region) and is_integer(page) do
		GenServer.call(via(region), {:fetch_gate, page})
	end

	@impl true
	def init({id, _opts}) do
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
			 cycle_id: nil,
			 started: MapSet.new(),
			 results: %{},
			 expected_pages: nil,
			 pages: MapSet.new(pages),
			 listeners: listeners
		 }}
	end

	@impl true
	def handle_call({:subscribe, pid}, _from, state) do
		{:reply, :ok, %{state | listeners: MapSet.put(state.listeners, pid)}}
	end

	@impl true
	def handle_call({:fetch_gate, page}, _from, state) do
		reply =
			cond do
				is_nil(state.expected_pages) -> if page == 1, do: :ok, else: :wait
				page <= state.expected_pages -> :ok
				true -> :gone
			end

		{:reply, reply, state}
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

		{:noreply, state}
	end

	@impl true
	def handle_cast({:update_page_count, count}, state) do
		count = max(count, 1)
		handle_page_count(count, state)
	end

	@impl true
	def handle_cast({:page_result, page, :failed, %{reason: :not_found} = context}, state)
			when is_integer(page) and page >= 2 do
		handle_cast({:page_result, page, :gone, context}, state)
	end

	@impl true
	def handle_cast({:page_result, page, :gone, context}, state) do
		cond do
			!is_integer(page) ->
				{:noreply, state}

			page < 2 ->
				reason = Map.get(context, :reason, :not_found)
				handle_cast({:page_result, page, :failed, %{reason: reason}}, state)

			!is_nil(state.expected_pages) and page - 1 >= state.expected_pages ->
				{:noreply, state}

			true ->
				{:noreply, apply_count(page - 1, state)}
		end
	end

	@impl true
	def handle_cast({:page_result, page, status, context}, state) do
		if MapSet.member?(state.started, page) do
			expected_pages = expected_pages(context, state.expected_pages, page)
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
	def handle_info(_message, state), do: {:noreply, state}

	defp handle_page_count(count, state) do
		{:noreply, apply_count(count, state)}
	end

	defp apply_count(count, state) do
		previous = state.expected_pages
		state = set_expected_pages(state, count)

		state =
			case check_cycle(state) do
				{:completed, event, state} -> emit(state, event)
				{:pending, state} -> state
			end

		state = note_page_count(state, previous, count)

		reconcile_pages(count, state)
	end

	defp note_page_count(state, previous, count) do
		if is_integer(previous) and previous != count do
			if count < previous, do: Etag.Database.prune_region(state.id, count)

			Marketmailer.Log.info(
				"page_count_changed",
				%{region: state.id, old: previous, new: count},
				"Region #{state.id}: pages #{previous} -> #{count}"
			)
		end

		state
	end

	# apply_count/2 runs on every page report, so this must not scan the
	# registry: state.pages tracks the workers we have started or stopped.
	defp reconcile_pages(count, state) do
		wanted = MapSet.new(1..count)
		missing = MapSet.difference(wanted, state.pages)
		extra = MapSet.difference(state.pages, wanted)

		Enum.each(missing, &start_page(state.id, &1))
		Enum.each(extra, &stop_page(state.id, &1))

		if MapSet.size(missing) > 0 do
			Marketmailer.Log.info(
				"region_pages_reconciled",
				%{region: state.id, pages: count, missing: MapSet.size(missing)},
				"Region #{state.id}: started #{MapSet.size(missing)} missing page workers"
			)
		end

		%{state | pages: wanted}
	end

	defp new_cycle(state) do
		%{state | cycle_id: nil, started: MapSet.new(), results: %{}}
	end

	defp set_expected_pages(%{expected_pages: previous} = state, count) when is_integer(previous) and previous > count do
		started = MapSet.filter(state.started, &(&1 <= count))
		results = Map.filter(state.results, fn {page, _result} -> page <= count end)
		%{state | expected_pages: count, started: started, results: results}
	end

	defp set_expected_pages(state, count), do: %{state | expected_pages: count}

	defp expected_pages(%{pages: pages}, _current, _page) when is_integer(pages) and pages > 0, do: pages
	defp expected_pages(_context, current, _page) when is_integer(current), do: current
	defp expected_pages(_context, nil, 1), do: 1
	defp expected_pages(_context, nil, _page), do: nil

	defp check_cycle(%{expected_pages: nil} = state), do: {:pending, state}

	defp check_cycle(%{expected_pages: expected_pages} = state) do
		# expected_pages is nil or a positive integer, so the key range is exact.
		if map_size(Map.take(state.results, 1..expected_pages)) == expected_pages do
			event = cycle_event(expected_pages, state)
			{:completed, event, new_cycle(%{state | expected_pages: expected_pages})}
		else
			{:pending, state}
		end
	end

	# One summary for every outcome; only the event name and level differ.
	defp cycle_event(expected_pages, state) do
		summary = %{
			region: state.id,
			cycle_id: state.cycle_id,
			pages: expected_pages,
			updated_pages: updated_pages(state.results)
		}

		failures = failures(state.results)
		statuses = Enum.map(state.results, fn {_page, result} -> result.status end)

		cond do
			failures != [] ->
				summary = Map.put(summary, :failures, failures)
				log_failure(summary)
				{:region_refresh_failed, summary}

			:updated in statuses ->
				Marketmailer.Log.info("region_refresh_complete", summary, "Region #{state.id} refresh complete")
				{:region_refresh_complete, summary}

			true ->
				Marketmailer.Log.info("region_refresh_unchanged", summary, "Region #{state.id} refresh unchanged")
				{:region_refresh_unchanged, summary}
		end
	end

	defp failures(results) do
		for {page, %{status: :failed, reason: reason}} <- results,
				do: %{page: page, reason: reason}
	end

	defp updated_pages(results) do
		pages = for {page, %{status: :updated}} <- results, do: page
		Enum.sort(pages)
	end

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
				do: DynamicSupervisor.terminate_child(Marketmailer.PageSup, pid)
	end
end
