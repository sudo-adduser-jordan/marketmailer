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
end
