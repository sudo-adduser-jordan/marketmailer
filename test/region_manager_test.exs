defmodule Marketmailer.RegionManagerTest do
	# Per-page fan-out with no HTTP and no DB writes: ESI maintenance mode is
	# forced active so PageWorkers park on their 10s timer instead of fetching.
	use ExUnit.Case, async: false

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)

		# `mix test` boots the app, which already starts Registry
		# (pollers stay disabled via `start_pollers: false`).
		# PageSup is a poller child, so tests provide it when absent.
		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		# Park every PageWorker: with maintenance active no worker calls ESI.
		MarketmailerTest.Fixtures.park_page_workers()

		:ok
	end

	test "page 1 reports its count and the manager fans out one worker per page" do
		region = 99_000_001
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		# Page 1 boots on init (parked, no fetch).
		assert [{_pid, _}] = Registry.lookup(Marketmailer.Registry, {:page, region, 1})

		# PageWorker 1 reports X-Pages -> manager provides workers for the rest.
		# The cast is fire-and-forget, so keep checking until workers appear.
		Marketmailer.RegionManager.page_count(region, 3)
		assert_all_pages(region, [1, 2, 3])

		assert %{page_count: 3} = :sys.get_state(manager)
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

		assert %{page_count: 1} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "duplicate page count spawns nothing new" do
		region = 99_000_003
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		before = DynamicSupervisor.count_children(Marketmailer.PageSup)
		Marketmailer.RegionManager.page_count(region, 1)
		# Asserting nothing happened: give the manager 200ms to misbehave first.
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

	test "format_ttl renders mm:ss" do
		assert Marketmailer.PageWorker.format_ttl(60_000) == "01:00"
		assert Marketmailer.PageWorker.format_ttl(90_000) == "01:30"
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

	test "fails a cycle that does not finish before its deadline" do
		region = 98_000_006
		start_cycle_manager(region)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 2})

		assert_receive {:region_refresh_failed, summary}, 500
		assert summary.region == region
		assert summary.failures == [%{page: 2, reason: :cycle_timeout}]
	end

	# Cycle tests drive the manager directly with a short deadline. Cleanup
	# stops the manager and its parked workers so no lingering worker wakes
	# up after maintenance mode is lifted.
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

	# Each lookup races the manager, which handles our `send` asynchronously:
	# retry until the workers appear (or 2s passes, then fail).
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

	# Same race in reverse: retry until the stopped workers disappear.
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
