defmodule Marketmailer.RegionManagerTest do
	use ExUnit.Case, async: false

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)

		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		MarketmailerTest.Fixtures.park_page_workers()
		MarketmailerTest.Fixtures.reset_network()

		:ok
	end

	test "manager creates one worker per valid page" do
	end

	test "page count matches workers" do
	end

	test "page workers stay alive during maintaince" do
	end

	test "emits a failure when any page fails" do
	end

	test "emits one success event when every page completes" do
	end

	test "handles when new regions are added" do
	end

	test "all workers report page count" do
	end
end
