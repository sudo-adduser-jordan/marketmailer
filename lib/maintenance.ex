defmodule Marketmailer.Maintenance do
	use GenServer

	@table :network_state
	@key :network

	@defaults [
		probe_host: "esi.evetech.net",
		probe_port: 443,
		probe_ms: 5_000,
		max_probe_ms: 60_000,
		probe_timeout_ms: 5_000,
		recheck_ms: 5_000,
		request_timeout_ms: 30_000
	]

	def config(overrides \\ []) do
		configured = Application.get_env(:marketmailer, :maintenance, [])
		configured = if is_list(configured), do: configured, else: []

		@defaults
		|> Keyword.merge(configured)
		|> Keyword.merge(overrides)
	end

	def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

	def subscribe(pid \\ self()) do
		case Process.whereis(__MODULE__) do
			nil -> :ok
			_ -> GenServer.cast(__MODULE__, {:subscribe, pid})
		end

		:ok
	end

	def up?, do: status().state == :up
	def down?, do: status().state == :down

	def status do
		case lookup() do
			%{state: :down} = status -> status
			_ -> %{state: :up, reason: nil, since_ms: nil, probes: 0}
		end
	end

	def recheck_ms, do: Keyword.fetch!(config(), :recheck_ms)

	def request_timeout_ms, do: Keyword.fetch!(config(), :request_timeout_ms)

	def report_disconnect(reason) do
		if up?() do
			write_status(%{state: :down, reason: describe(reason), since_ms: now_ms(), probes: 0})

			case Process.whereis(__MODULE__) do
				nil -> :ok
				_ -> GenServer.cast(__MODULE__, {:down, reason})
			end
		end

		:ok
	end

	def report_suspect(reason) do
		if up?() do
			case Process.whereis(__MODULE__) do
				nil -> :ok
				_ -> GenServer.cast(__MODULE__, {:suspect, reason})
			end
		end

		:ok
	end

	def report_connected do
		if down?() do
			write_status(up_status())

			case Process.whereis(__MODULE__) do
				nil -> :ok
				_ -> GenServer.cast(__MODULE__, :up)
			end
		end

		:ok
	end

	def reset do
		case Process.whereis(__MODULE__) do
			nil ->
				write_status(up_status())
				:ok

			_ ->
				GenServer.call(__MODULE__, :reset)
		end
	end

	@impl true
	def init(opts) do
		config = config(opts)
		ensure_table()

		if lookup() == nil do
			write_status(up_status())
		end

		phase = if down?(), do: :down, else: :up

		state = %{
			config: config,
			probe_fun: Keyword.get(config, :probe_fun, &default_probe/3),
			phase: phase,
			down_since: status().since_ms,
			probes: 0,
			suspect: nil,
			timer: nil,
			subscribers: MapSet.new()
		}

		state = if phase == :down, do: schedule_probe(state, 0), else: state
		{:ok, state}
	end

	@impl true
	def handle_call(:reset, _from, state) do
		cancel_timer(state.timer)
		write_status(up_status())

		{:reply, :ok, %{state | phase: :up, down_since: nil, probes: 0, suspect: nil, timer: nil}}
	end

	@impl true
	def handle_cast({:subscribe, pid}, state) do
		{:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
	end

	def handle_cast({:down, reason}, state) do
		if state.phase == :down do
			{:noreply, ensure_probe(state)}
		else
			config = state.config

			Marketmailer.Log.warning(
				"network_lost",
				%{reason: describe(reason), host: config[:probe_host], port: config[:probe_port]},
				"Network connection lost; polling paused"
			)

			notify(state, :down)

			state
			|> Map.merge(%{phase: :down, down_since: status().since_ms, probes: 0, suspect: nil})
			|> ensure_probe()
			|> then(&{:noreply, &1})
		end
	end

	def handle_cast({:suspect, reason}, %{phase: :up} = state) do
		state = if is_nil(state.suspect), do: %{state | suspect: reason}, else: state
		{:noreply, ensure_probe(state)}
	end

	def handle_cast({:suspect, _reason}, state), do: {:noreply, state}

	def handle_cast(:up, state) do
		if state.phase == :up do
			{:noreply, state}
		else
			{:noreply, mark_up(state)}
		end
	end

	@impl true
	def handle_info(:probe, state) do
		cond do
			down?() -> {:noreply, run_probe(%{state | timer: nil})}
			not is_nil(state.suspect) -> {:noreply, probe_suspect(%{state | timer: nil})}
			true -> {:noreply, %{state | phase: :up, down_since: nil, suspect: nil, timer: nil}}
		end
	end

	def handle_info(_message, state), do: {:noreply, state}

	defp probe_suspect(state) do
		config = state.config
		result = run_probe_fun(state)

		case result do
			:ok ->
				Marketmailer.Log.info(
					"network_probe_ok",
					%{reason: describe(state.suspect), host: config[:probe_host], port: config[:probe_port]},
					"Network probe succeeded; polling continues"
				)

				%{state | suspect: nil, timer: nil}

			{:error, reason} ->
				enter_down(%{state | timer: nil}, state.suspect || reason)

			other ->
				enter_down(%{state | timer: nil}, state.suspect || other)
		end
	rescue
		error -> enter_down(%{state | timer: nil}, state.suspect || error)
	end

	defp enter_down(state, reason) do
		config = state.config
		now = now_ms()

		write_status(%{state: :down, reason: describe(reason), since_ms: now, probes: 1})

		Marketmailer.Log.warning(
			"network_lost",
			%{reason: describe(reason), host: config[:probe_host], port: config[:probe_port]},
			"Network connection lost; polling paused"
		)

		notify(state, :down)

		state
		|> Map.merge(%{phase: :down, down_since: now, probes: 1, suspect: nil})
		|> schedule_probe(probe_delay(config, 1))
	end

	defp run_probe(state) do
		case run_probe_fun(state) do
			:ok -> mark_up(state)
			{:error, reason} -> probe_failed(state, reason)
			other -> probe_failed(state, other)
		end
	rescue
		error -> probe_failed(state, error)
	end

	defp run_probe_fun(state) do
		config = state.config
		state.probe_fun.(config[:probe_host], config[:probe_port], config[:probe_timeout_ms])
	end

	defp probe_failed(state, reason) do
		probes = state.probes + 1
		current = status()
		reason = current.reason || describe(reason)

		write_status(%{current | probes: probes, reason: reason})

		state
		|> Map.merge(%{phase: :down, probes: probes})
		|> schedule_probe(probe_delay(state.config, probes))
	end

	defp mark_up(state) do
		now = now_ms()
		down_since = state.down_since || status().since_ms
		downtime = if is_integer(down_since), do: max(now - down_since, 0), else: 0

		cancel_timer(state.timer)
		write_status(up_status())

		Marketmailer.Log.info(
			"network_restored",
			%{downtime_ms: downtime, probes: state.probes},
			"Network connection restored after #{div(downtime, 1_000)}s"
		)

		notify(state, :up)
		%{state | phase: :up, down_since: nil, probes: 0, suspect: nil, timer: nil}
	end

	defp probe_delay(config, probes) do
		base = Keyword.fetch!(config, :probe_ms)
		max = Keyword.fetch!(config, :max_probe_ms)
		(base * :math.pow(2, min(probes - 1, 10))) |> round() |> min(max)
	end

	defp ensure_probe(%{timer: nil} = state), do: schedule_probe(state, 0)
	defp ensure_probe(state), do: state

	defp schedule_probe(state, delay) do
		cancel_timer(state.timer)
		%{state | timer: Process.send_after(self(), :probe, delay)}
	end

	defp cancel_timer(nil), do: :ok
	defp cancel_timer(ref), do: Process.cancel_timer(ref)

	defp notify(state, status) do
		Enum.each(state.subscribers, &send(&1, {:maintenance, status}))
	end

	defp default_probe(host, port, timeout) do
		case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, nodelay: true], timeout) do
			{:ok, socket} ->
				:gen_tcp.close(socket)
				:ok

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp up_status, do: %{state: :up, reason: nil, since_ms: nil, probes: 0}

	defp lookup do
		case :ets.whereis(@table) do
			:undefined ->
				nil

			_ ->
				case :ets.lookup(@table, @key) do
					[{@key, status}] -> status
					_ -> nil
				end
		end
	rescue
		ArgumentError -> nil
	end

	defp write_status(status) do
		if :ets.whereis(@table) != :undefined do
			:ets.insert(@table, {@key, status})
		end

		:ok
	end

	defp ensure_table do
		if :ets.whereis(@table) == :undefined do
			:ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
		end

		:ok
	end

	defp now_ms, do: System.system_time(:millisecond)

	defp describe(%{__exception__: true} = error), do: Exception.message(error)
	defp describe(reason) when is_atom(reason) or is_binary(reason), do: inspect(reason)
	defp describe(reason), do: inspect(reason, limit: 4)
end
