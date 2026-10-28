defmodule ESI.Maintenance do
	use GenServer

	@table :esi_error_state
	@mode_key :maintenance_mode
	@since_key :maintenance_since

	@gate_ms 86_400_000

	@defaults [
		stale_after_ms: 30 * 60_000,
		stale_every_ms: 10 * 60_000,
		tick_ms: 60_000,
		announce_grace_ms: 5_000,
		close_grace_ms: 5_000
	]

	def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

	def config(overrides \\ []) do
		configured = Application.get_env(:marketmailer, :esi_maintenance, [])
		configured = if is_list(configured), do: configured, else: []

		@defaults
		|> Keyword.merge(configured)
		|> Keyword.merge(overrides)
	end

	def subscribe(pid \\ self()) do
		case Process.whereis(__MODULE__) do
			nil -> :ok
			server -> GenServer.call(server, {:subscribe, pid})
		end
	end

	def down? do
		now = now_ms()

		case lookup(@mode_key) do
			[{@mode_key, until}] when is_integer(until) -> until > now
			_ -> false
		end
	end

	def window_open? do
		lookup(@since_key) != []
	end

	def state do
		case lookup(@since_key) do
			[{@since_key, %{since_ms: since_ms, reason: reason}}] ->
				%{down: down?(), since_ms: since_ms, reason: describe(reason), downtime_ms: now_ms() - since_ms}

			_ ->
				%{down: false, since_ms: nil, reason: nil, downtime_ms: 0}
		end
	end

	def down(reason) do
		ensure_table()
		now = now_ms()

		if :ets.insert_new(@table, {@since_key, %{since_ms: now, reason: reason}}) do
			:ets.insert(@table, {@mode_key, now + @gate_ms})
			notify({:down_reported})
		else
			:ets.insert(@table, {@mode_key, now + @gate_ms})
		end

		:ok
	end

	def up do
		ensure_table()

		case :ets.take(@table, @since_key) do
			[{@since_key, %{since_ms: since_ms}}] ->
				:ets.delete(@table, @mode_key)
				notify({:up_reported, since_ms})
				:ok

			_ ->
				:ok
		end
	end

	def reset do
		ensure_table()
		:ets.delete(@table, @since_key)
		:ets.delete(@table, @mode_key)
		notify({:reset_announce})
		:ok
	end

	@impl true
	def init(_opts) do
		ensure_table()

		{:ok,
		 %{
			 subscribers: MapSet.new(),
			 last_stale: nil,
			 down_announced: false,
			 down_timer: nil,
			 up_timer: nil,
			 timer: Process.send_after(self(), :tick, Keyword.fetch!(config(), :tick_ms))
		 }}
	end

	@impl true
	def handle_call({:subscribe, pid}, _from, state) do
		{:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
	end

	@impl true
	def handle_cast({:down_reported}, state) do
		state = cancel_up_timer(state)

		cond do
			announced?(state) ->
				{:noreply, state}

			not is_nil(Map.get(state, :down_timer)) ->
				{:noreply, state}

			true ->
				grace = Keyword.fetch!(config(), :announce_grace_ms)
				{:noreply, Map.put(state, :down_timer, Process.send_after(self(), :down_grace, grace))}
		end
	end

	def handle_cast({:up_reported, since_ms}, state) do
		state = cancel_down_timer(state)

		if announced?(state) and is_nil(Map.get(state, :up_timer)) do
			grace = Keyword.fetch!(config(), :close_grace_ms)
			{:noreply, Map.put(state, :up_timer, {Process.send_after(self(), :up_grace, grace), since_ms})}
		else
			{:noreply, state}
		end
	end

	def handle_cast({:reset_announce}, state) do
		{:noreply, clear_timers(Map.put(state, :down_announced, false))}
	end

	@impl true
	def handle_info(:down_grace, state) do
		state = Map.put(state, :down_timer, nil)

		case lookup(@since_key) do
			[{@since_key, %{since_ms: since_ms, reason: reason}}] ->
				Marketmailer.Log.warning(
					"esi_maintenance_down",
					%{reason: describe(reason), since_ms: since_ms},
					"ESI is unavailable (#{describe(reason)}); polling paused"
				)

				deliver(
					{:esi_maintenance, :down, %{since_ms: since_ms, reason: describe(reason)}},
					state
				)

				{:noreply, Map.put(state, :down_announced, true)}

			_ ->
				{:noreply, state}
		end
	end

	def handle_info(:up_grace, state) do
		{_ref, since_ms} =
			case Map.get(state, :up_timer) do
				{ref, since} -> {ref, since}
				_ -> {nil, now_ms()}
			end

		state = Map.put(state, :up_timer, nil)

		if announced?(state) and lookup(@since_key) == [] do
			downtime = now_ms() - since_ms

			Marketmailer.Log.info(
				"esi_maintenance_up",
				%{downtime_ms: downtime},
				"ESI is back after #{div(downtime, 1_000)}s; polling resumed"
			)

			deliver({:esi_maintenance, :up, %{downtime_ms: downtime}}, state)
			{:noreply, Map.put(state, :down_announced, false)}
		else
			{:noreply, state}
		end
	end

	def handle_info(:tick, state) do
		config = config()
		state = %{state | timer: Process.send_after(self(), :tick, Keyword.fetch!(config, :tick_ms))}
		{:noreply, note_stale(state, config)}
	end

	def handle_info(_message, state), do: {:noreply, state}

	defp note_stale(state, config) do
		status = state_now()
		stale_after = Keyword.fetch!(config, :stale_after_ms)
		stale_every = Keyword.fetch!(config, :stale_every_ms)

		if status.down and status.downtime_ms >= stale_after do
			now = now_ms()

			if is_nil(state.last_stale) or now - state.last_stale >= stale_every do
				Marketmailer.Log.warning(
					"esi_maintenance_stale",
					%{downtime_ms: status.downtime_ms, reason: status.reason},
					"ESI has been unavailable for #{div(status.downtime_ms, 60_000)}m; polling still paused"
				)

				%{state | last_stale: now}
			else
				state
			end
		else
			%{state | last_stale: nil}
		end
	end

	defp state_now do
		case lookup(@since_key) do
			[{@since_key, %{since_ms: since_ms, reason: reason}}] ->
				%{down: true, since_ms: since_ms, reason: describe(reason), downtime_ms: now_ms() - since_ms}

			_ ->
				%{down: false, since_ms: nil, reason: nil, downtime_ms: 0}
		end
	end

	defp notify(event) do
		case Process.whereis(__MODULE__) do
			nil -> :ok
			server -> GenServer.cast(server, event)
		end

		:ok
	end

	defp deliver(event, state) do
		Enum.each(state.subscribers, &send(&1, event))
		:ok
	end

	defp announced?(state), do: Map.get(state, :down_announced, false) == true

	defp cancel_down_timer(state) do
		if ref = Map.get(state, :down_timer), do: Process.cancel_timer(ref)
		Map.put(state, :down_timer, nil)
	end

	defp cancel_up_timer(state) do
		case Map.get(state, :up_timer) do
			{ref, _since} -> Process.cancel_timer(ref)
			_ -> :ok
		end

		Map.put(state, :up_timer, nil)
	end

	defp clear_timers(state) do
		state |> cancel_down_timer() |> cancel_up_timer()
	end

	defp describe(%{status: status}) when is_integer(status), do: "HTTP #{status}"
	defp describe(%{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
	defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
	defp describe(reason), do: inspect(reason)

	defp lookup(key) do
		ensure_table()
		:ets.lookup(@table, key)
	end

	defp ensure_table do
		if :ets.whereis(@table) == :undefined do
			:ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
		end

		:ok
	end

	defp now_ms, do: System.system_time(:millisecond)
end
