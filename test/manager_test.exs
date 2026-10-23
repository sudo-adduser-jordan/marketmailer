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

	test "page 1 reports its count and the manager fans out one worker per page" do
		region = 99_000_001
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		assert [{_pid, _}] = Registry.lookup(Marketmailer.Registry, {:page, region, 1})

		Marketmailer.RegionManager.page_count(region, 3)
		assert_all_pages(region, [1, 2, 3])

		assert %{expected_pages: 3} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "shrinking page count stops the extra workers" do
		region = 99_000_002
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Marketmailer.RegionManager.page_count(region, 3)
		assert_all_pages(region, [1, 2, 3])

		Marketmailer.RegionManager.page_count(region, 1)
		assert_no_pages(region, [2, 3])
		assert_all_pages(region, [1])

		assert %{expected_pages: 1} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "duplicate page count spawns nothing new" do
		region = 99_000_003
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		before = DynamicSupervisor.count_children(Marketmailer.PageSup)
		Marketmailer.RegionManager.page_count(region, 1)
		Process.sleep(200)

		assert DynamicSupervisor.count_children(Marketmailer.PageSup) == before
		assert_all_pages(region, [1])
		GenServer.stop(manager, :normal)
	end

	test "a page worker stays alive under maintenance without fetching" do
		region = 99_000_004
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)
		[{worker, _}] = Registry.lookup(Marketmailer.Registry, {:page, region, 1})

		Process.sleep(200)
		assert Process.alive?(worker)
		assert Process.alive?(manager)
		GenServer.stop(manager, :normal)
	end

	test "emits one success event when every page completes" do
		region = 98_000_001
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 2})
		Marketmailer.RegionManager.page_started(region, 2)
		Marketmailer.RegionManager.page_result(region, 2, :not_modified, %{pages: 2})

		assert_receive {:region_refresh_complete, summary}
		assert summary.region == region
		assert summary.pages == 2
		assert summary.updated_pages == [1]
		assert is_integer(summary.cycle_id)
		refute_receive {:region_refresh_complete, _summary}, 150
	end

	test "emits an unchanged event for an all-not-modified cycle" do
		region = 98_000_002
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :not_modified, %{pages: 1})

		assert_receive {:region_refresh_unchanged, summary}
		assert summary.region == region
		assert summary.pages == 1
		assert summary.updated_pages == []
		assert is_integer(summary.cycle_id)
		refute_receive {:region_refresh_complete, _summary}, 150
	end

	test "emits a failure when any page fails" do
		region = 98_000_003
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :failed, %{pages: 2, reason: :timeout})
		Marketmailer.RegionManager.page_started(region, 2)
		Marketmailer.RegionManager.page_result(region, 2, :updated, %{pages: 2})

		assert_receive {:region_refresh_failed, summary}
		assert summary.region == region
		assert summary.pages == 2
		assert summary.failures == [%{page: 1, reason: :timeout}]
	end

	test "ignores duplicate results after a cycle has completed" do
		region = 98_000_004
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 1})
		assert_receive {:region_refresh_complete, _summary}

		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 1})
		refute_receive {:region_refresh_complete, _summary}, 150

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 1})
		assert_receive {:region_refresh_complete, _summary}
	end

	test "updates the expected page set when the region count changes" do
		region = 98_000_005
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 3})
		Marketmailer.RegionManager.page_count(region, 1)

		assert_receive {:region_refresh_complete, %{pages: 1}}
	end

	test "an unfinished cycle emits nothing until every page reports" do
		region = 98_000_006
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 2})

		refute_receive {:region_refresh_failed, _summary}, 300
		refute_receive {:region_refresh_complete, _summary}, 100

		Marketmailer.RegionManager.page_started(region, 2)
		Marketmailer.RegionManager.page_result(region, 2, :updated, %{pages: 2})

		assert_receive {:region_refresh_complete, summary}, 500
		assert summary.region == region
	end

	test "fetch_gate allows page 1 before any count and parks higher pages" do
		region = 99_000_011
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		assert Marketmailer.RegionManager.fetch_gate(region, 1) == :ok
		assert Marketmailer.RegionManager.fetch_gate(region, 2) == :wait
		GenServer.stop(manager, :normal)
	end

	test "fetch_gate denies pages above the known count" do
		region = 99_000_012
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Marketmailer.RegionManager.page_count(region, 2)
		assert_all_pages(region, [1, 2])

		assert Marketmailer.RegionManager.fetch_gate(region, 2) == :ok
		assert Marketmailer.RegionManager.fetch_gate(region, 3) == :gone
		GenServer.stop(manager, :normal)
	end

	test "a gone report shrinks the region and stops the dead workers" do
		region = 99_000_013
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Marketmailer.RegionManager.page_count(region, 3)
		assert_all_pages(region, [1, 2, 3])

		Marketmailer.RegionManager.page_result(region, 3, :gone, %{reason: :not_found})
		assert_no_pages(region, [3])
		assert_all_pages(region, [1, 2])

		assert %{expected_pages: 2} = :sys.get_state(manager)
		assert Marketmailer.RegionManager.fetch_gate(region, 3) == :gone
		GenServer.stop(manager, :normal)
	end

	test "a not_found failure shrinks like a gone report" do
		region = 99_000_014
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Marketmailer.RegionManager.page_count(region, 2)
		assert_all_pages(region, [1, 2])

		Marketmailer.RegionManager.page_result(region, 2, :failed, %{reason: :not_found})
		assert_no_pages(region, [2])
		assert_all_pages(region, [1])

		assert %{expected_pages: 1} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "a gone report at or below the known count changes nothing" do
		region = 99_000_015
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		Marketmailer.RegionManager.page_count(region, 3)
		assert_all_pages(region, [1, 2, 3])

		Marketmailer.RegionManager.page_result(region, 5, :gone, %{reason: :not_found})
		assert_all_pages(region, [1, 2, 3])
		assert %{expected_pages: 3} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "spawns the pages the etags never recorded when ESI's count is unchanged" do
		region = 99_000_016

		# The production wedge: the DB only knows scattered pages and page 1
		# reports a count equal to the highest known page, so a manager that
		# trusts the etags row count sees nothing new to start.
		for page <- [1, 2, 5] do
			Etag.Database.upsert_etag(
				"https://esi.evetech.net/v1/markets/#{region}/orders/?page=#{page}",
				"etag-#{page}"
			)
		end

		on_exit(fn -> Etag.Database.prune_region(region, 0) end)

		{:ok, manager} = Marketmailer.RegionManager.start_link(region)
		assert_all_pages(region, [1, 2, 5])

		Marketmailer.RegionManager.page_count(region, 5)
		assert_all_pages(region, [1, 2, 3, 4, 5])

		GenServer.stop(manager, :normal)
	end

	test "a page 1 failure still closes the cycle instead of going silent" do
		region = 98_000_007
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :failed, %{reason: :offline})

		assert_receive {:region_refresh_failed, summary}, 500
		assert summary.region == region
		assert summary.pages == 1
		assert summary.failures == [%{page: 1, reason: :offline}]
	end

	test "a page other than page 1 can change the region count" do
		region = 98_000_008
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 2})

		Marketmailer.RegionManager.page_started(region, 2)
		Marketmailer.RegionManager.page_result(region, 2, :updated, %{pages: 3})
		refute_receive {:region_refresh_complete, _summary}, 150

		Marketmailer.RegionManager.page_count(region, 3)
		assert_all_pages(region, [2, 3])

		Marketmailer.RegionManager.page_started(region, 3)
		Marketmailer.RegionManager.page_result(region, 3, :not_modified, %{pages: 3})

		assert_receive {:region_refresh_complete, summary}, 500
		assert summary.pages == 3
		assert summary.updated_pages == [1, 2]
	end

	defp start_cycle_manager(region, timeout \\ 100) do
		{:ok, manager} = Marketmailer.RegionManager.start_link(region, cycle_timeout: timeout)
		:ok = Marketmailer.RegionManager.subscribe(region, self())

		on_exit(fn ->
			for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, region, 1}) do
				try do
					GenServer.stop(pid, :normal)
				catch
					:exit, _ -> :ok
				end
			end

			try do
				GenServer.stop(manager, :normal)
			catch
				:exit, _ -> :ok
			end
		end)

		manager
	end

	defp assert_all_pages(region, pages, timeout \\ 2_000) do
		deadline = System.monotonic_time(:millisecond) + timeout

		for page <- pages do
			await_page(region, page, deadline)
		end
	end

	defp await_page(region, page, deadline) do
		case Registry.lookup(Marketmailer.Registry, {:page, region, page}) do
			[{_pid, _}] ->
				:ok

			[] ->
				if System.monotonic_time(:millisecond) > deadline do
					flunk("expected a worker for region #{region} page #{page}")
				else
					Process.sleep(10)
					await_page(region, page, deadline)
				end
		end
	end

	defp assert_no_pages(region, pages, timeout \\ 2_000) do
		deadline = System.monotonic_time(:millisecond) + timeout

		for page <- pages do
			await_no_page(region, page, deadline)
		end
	end

	defp await_no_page(region, page, deadline) do
		case Registry.lookup(Marketmailer.Registry, {:page, region, page}) do
			[] ->
				:ok

			_ ->
				if System.monotonic_time(:millisecond) > deadline do
					flunk("expected no worker for region #{region} page #{page}")
				else
					Process.sleep(10)
					await_no_page(region, page, deadline)
				end
		end
	end
end
