defmodule ESI.Maintenance do
	@moduledoc false
	# ESI availability, edge-based instead of TTL-based.
	#
	# `ESI.get/2` reports every 5xx and every request that never got an answer
	# (pool exhaustion, timeout) here; the first one turns the fleet's pause gate
	# on and the first 200/304 afterwards turns it off. The gate used to expire on
	# its own after @maint_ping_ms, so a window that lasted longer than one probe
	# interval let every worker fetch again — this process owns the window instead,
	# including the "still down" watchdog and the events `Discord.Broadcaster`
	# turns into the yellow/green embeds.
	#
	# The flag lives in `:esi_error_state` (`:maintenance_mode` is a deadline so
	# `maintenance_active?/0` stays a cheap ETS read for thousands of workers,
	# `:maintenance_since` carries the cause). `down/1` and `up/0` write ETS
	# themselves — no GenServer round trip in the hot path — and only the edge
	# that flips the state is announced, atomically, through insert_new/take.
	use GenServer

	@table :esi_error_state
	@mode_key :maintenance_mode
	@since_key :maintenance_since

	# The gate is refreshed on every report while ESI answers with 5xx; it only
	# exists to answer "is ESI down right now" without a process call.
	@gate_ms 86_400_000

	@defaults [
		stale_after_ms: 30 * 60_000,
		stale_every_ms: 10 * 60_000,
		tick_ms: 60_000
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

	# Cheap read for the page workers: one ETS lookup, no call.
	def down? do
		now = now_ms()

		case lookup(@mode_key) do
			[{@mode_key, until}] when is_integer(until) -> until > now
			_ -> false
		end
	end

	# A window that was announced (a real down edge) as opposed to the pause gate
	# alone, which tests and operators also park workers with.
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

	# First failure of a window announces; every later one only extends the gate.
	def down(reason) do
		ensure_table()
		now = now_ms()

		if :ets.insert_new(@table, {@since_key, %{since_ms: now, reason: reason}}) do
			Marketmailer.Log.warning(
				"esi_maintenance_down",
				%{reason: describe(reason), since_ms: now},
				"ESI is unavailable (#{describe(reason)}); polling paused"
			)

			:ets.insert(@table, {@mode_key, now + @gate_ms})
			announce({:esi_maintenance, :down, %{since_ms: now, reason: describe(reason)}})
		else
			:ets.insert(@table, {@mode_key, now + @gate_ms})
		end

		:ok
	end

	# First success after a window closes it; a success while up is a no-op.
	def up do
		ensure_table()

		case :ets.take(@table, @since_key) do
			[{@since_key, %{since_ms: since_ms}}] ->
				:ets.delete(@table, @mode_key)
				downtime = now_ms() - since_ms

				Marketmailer.Log.info(
					"esi_maintenance_up",
					%{downtime_ms: downtime},
					"ESI is back after #{div(downtime, 1_000)}s; polling resumed"
				)

				announce({:esi_maintenance, :up, %{downtime_ms: downtime}})
				:ok

			_ ->
				:ok
		end
	end

	# Test/operator helper: clear the window without announcing it.
	def reset do
		ensure_table()
		:ets.delete(@table, @since_key)
		:ets.delete(@table, @mode_key)
		:ok
	end

	@impl true
	def init(_opts) do
		ensure_table()

		{:ok,
		 %{
			 subscribers: MapSet.new(),
			 last_stale: nil,
			 timer: Process.send_after(self(), :tick, Keyword.fetch!(config(), :tick_ms))
		 }}
	end

	@impl true
	def handle_call({:subscribe, pid}, _from, state) do
		{:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
	end

	@impl true
	def handle_cast({:announce, event}, state) do
		Enum.each(state.subscribers, &send(&1, event))
		{:noreply, state}
	end

	@impl true
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

	defp announce(event) do
		case Process.whereis(__MODULE__) do
			nil -> :ok
			server -> GenServer.cast(server, {:announce, event})
		end

		:ok
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
