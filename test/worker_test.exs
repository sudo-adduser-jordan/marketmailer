defmodule Marketmailer.PageWorkerGateTest do
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

	test "worker does not fetch when out of page count bounds" do
	end

	test "worker pauses when count is unknown" do
	end

	test "worker can pause" do
	end

	test "worker pauses while the esi is down" do
	end

	test "worker pauses while the network is down" do
	end

	test "worker resumes fetching" do
	end
end
