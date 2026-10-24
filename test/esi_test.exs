defmodule ESI.ClientTest do
	use ExUnit.Case, async: false

	setup do
		if :ets.whereis(:market_cache) == :undefined do
			:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		end

		if :ets.whereis(:esi_error_state) == :undefined do
			:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])
		end

		if :ets.whereis(:esi_rate_state) == :undefined do
			:ets.new(:esi_rate_state, [:named_table, :set, :public, read_concurrency: true])
		end

		if :ets.whereis(:network_state) == :undefined do
			:ets.new(:network_state, [:named_table, :set, :public, read_concurrency: true])
		end

		:ets.match_delete(:esi_rate_state, {{:rate_block, :_}, :_})
		:ets.match_delete(:esi_rate_state, {{:rate_group, :_}, :_})
		MarketmailerTest.Fixtures.reset_network()

		ExUnit.Callbacks.on_exit(fn -> MarketmailerTest.Fixtures.reset_network() end)

		:ok
	end

	test "handles rate limit" do
	end

	test "handles errors" do
	end

	test "handles status codes" do
	end

	test "handles etags" do
	end

	test "handles timeouts" do
	end

	test "handles transport errors" do
	end

	test "error limit does not fall below limit-1" do
	end

	defp eventually(fun, attempts \\ 50) do
		cond do
			fun.() ->
				true

			attempts <= 0 ->
				false

			true ->
				Process.sleep(10)
				eventually(fun, attempts - 1)
		end
	end
end
