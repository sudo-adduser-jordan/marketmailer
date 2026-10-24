defmodule MarketmailerTest.Fixtures do
	@park_window_ms 120_000

	def ensure_ets(name, opts \\ [:named_table, :set, :public]) do
		case :ets.whereis(name) do
			:undefined -> :ets.new(name, opts)
			_tid -> :ok
		end
	end

	def park_page_workers do
		:ets.insert(:esi_error_state, {:maintenance_mode, System.system_time(:millisecond) + @park_window_ms})

		ExUnit.Callbacks.on_exit(fn ->
			:ets.delete(:esi_error_state, :maintenance_mode)
		end)

		:ok
	end

	def network_down(reason \\ :econnrefused) do
		ensure_ets(:network_state, [:named_table, :set, :public, read_concurrency: true])

		:ets.insert(
			:network_state,
			{:network, %{state: :down, reason: inspect(reason), since_ms: System.system_time(:millisecond), probes: 0}}
		)

		ExUnit.Callbacks.on_exit(fn ->
			if :ets.whereis(:network_state) != :undefined do
				:ets.delete(:network_state, :network)
			end
		end)

		:ok
	end

	def reset_network do
		ensure_ets(:network_state, [:named_table, :set, :public, read_concurrency: true])

		if Process.whereis(Marketmailer.Maintenance) do
			Marketmailer.Maintenance.reset()
		else
			:ets.delete(:network_state, :network)
		end

		:ok
	end
end
