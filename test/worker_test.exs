defmodule Marketmailer.PageWorkerTest do
	use ExUnit.Case, async: true

	test "format_ttl renders mm:ss" do
		assert Marketmailer.PageWorker.format_ttl(60_000) == "01:00"
		assert Marketmailer.PageWorker.format_ttl(90_000) == "01:30"
	end
end

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

	test "worker for a page above the known count stops without fetching" do
		region = 99_000_021
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)
		Marketmailer.RegionManager.page_count(region, 1)

		{:ok, worker} =
			DynamicSupervisor.start_child(
				Marketmailer.PageSup,
				{Marketmailer.PageWorker, {manager, region, 3}}
			)

		ref = Process.monitor(worker)
		assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 2_000
		assert Marketmailer.RegionManager.fetch_gate(region, 3) == :gone
		GenServer.stop(manager, :normal)
	end

	test "worker parks while the count is unknown" do
		region = 99_000_022
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		{:ok, worker} =
			DynamicSupervisor.start_child(
				Marketmailer.PageSup,
				{Marketmailer.PageWorker, {manager, region, 2}}
			)

		Process.sleep(300)
		assert Process.alive?(worker)
		assert Marketmailer.RegionManager.fetch_gate(region, 2) == :wait

		GenServer.stop(worker, :normal)
		GenServer.stop(manager, :normal)
	end

	test "a worker parks while the network is down without opening a cycle" do
		MarketmailerTest.Fixtures.network_down()

		region = 99_000_023
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Process.sleep(250)

		assert %{started: started} = :sys.get_state(manager)
		assert MapSet.size(started) == 0
		assert Process.alive?(manager)

		GenServer.stop(manager, :normal)
	end

	test "a parked worker resumes fetching after the network returns" do
		MarketmailerTest.Fixtures.network_down()
		:ets.delete(:esi_error_state, :maintenance_mode)

		test_pid = self()
		previous = Application.get_env(:marketmailer, :esi_http_fun)

		Application.put_env(:marketmailer, :esi_http_fun, fn _url, _opts ->
			send(test_pid, :fetched)
			{:ok, %{status: 304, headers: %{"x-pages" => ["1"]}, body: ""}}
		end)

		on_exit(fn ->
			if previous do
				Application.put_env(:marketmailer, :esi_http_fun, previous)
			else
				Application.delete_env(:marketmailer, :esi_http_fun)
			end
		end)

		region = 99_000_024
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Process.sleep(150)
		refute_received :fetched

		Marketmailer.Maintenance.report_connected()
		assert Marketmailer.Maintenance.up?()

		assert_receive :fetched, 2_000

		GenServer.stop(manager, :normal)
	end
end
