defmodule Marketmailer.RegionManagerTest do
	use ExUnit.Case, async: false

	alias Marketmailer.RegionManager

	@region 99_000_201
	@other_region 99_000_202

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)
		MarketmailerTest.Fixtures.ensure_ets(:esi_rate_state)

		for key <- [:maintenance_mode, :maintenance_ping, :blocked_until], do: :ets.delete(:esi_error_state, key)
		MarketmailerTest.Fixtures.reset_esi_maintenance()
		:ets.match_delete(:esi_rate_state, {{:rate_block, :_}, :_})
		:ets.match_delete(:esi_rate_state, {{:rate_group, :_}, :_})

		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		# Park every worker and hold the maintenance ping so no test fetches.
		MarketmailerTest.Fixtures.park_page_workers()
		:ets.insert(:esi_error_state, {:maintenance_ping, System.system_time(:millisecond) + 60_000})
		MarketmailerTest.Fixtures.reset_network()

		on_exit(fn ->
			for region <- [@region, @other_region], do: stop_region(region)
		end)

		:ok
	end

	test "manager creates one worker per valid page" do
		start_manager(@region)

		RegionManager.page_started(@region, 1)
		RegionManager.page_result(@region, 1, :updated, %{pages: 3})
		RegionManager.page_count(@region, 3)
		sync(@region)

		assert page_ids(@region) == [1, 2, 3]
	end

	test "page count matches workers" do
		manager = start_manager(@region)

		RegionManager.page_count(@region, 4)
		:sys.get_state(manager)
		assert page_ids(@region) == [1, 2, 3, 4]

		RegionManager.page_count(@region, 2)
		:sys.get_state(manager)
		assert await_pages(@region, [1, 2]) == [1, 2]
	end

	test "page workers stay alive during maintaince" do
		start_manager(@region)

		RegionManager.page_started(@region, 1)
		RegionManager.page_result(@region, 1, :updated, %{pages: 3})
		RegionManager.page_count(@region, 3)
		sync(@region)

		workers = Enum.map(1..3, &page_worker(@region, &1))
		Enum.each(workers, &send(&1, :work))
		Process.sleep(100)

		assert Enum.all?(workers, &Process.alive?/1)
		assert page_ids(@region) == [1, 2, 3]
	end

	test "emits a failure when any page fails" do
		start_manager(@region)
		RegionManager.subscribe(@region)

		RegionManager.page_started(@region, 1)
		RegionManager.page_started(@region, 2)
		RegionManager.page_result(@region, 1, :updated, %{pages: 2})
		RegionManager.page_result(@region, 2, :failed, %{pages: 2, reason: :boom})

		assert_receive {:region_refresh_failed, summary}, 1_000
		assert summary.pages == 2
		assert summary.failures == [%{page: 2, reason: :boom}]
	end

	test "emits one success event when every page completes" do
		start_manager(@region)
		RegionManager.subscribe(@region)

		for page <- 1..2, do: RegionManager.page_started(@region, page)
		RegionManager.page_result(@region, 1, :updated, %{pages: 2})
		RegionManager.page_result(@region, 2, :updated, %{pages: 2})

		assert_receive {:region_refresh_complete, summary}, 1_000
		assert summary.pages == 2
		assert summary.updated_pages == [1, 2]
		refute_receive {:region_refresh_complete, _summary}, 100
	end

	test "handles when new regions are added" do
		start_manager(@region)
		assert page_ids(@region) == [1]

		start_manager(@other_region)
		assert page_ids(@other_region) == [1]

		RegionManager.page_started(@other_region, 1)
		RegionManager.page_result(@other_region, 1, :updated, %{pages: 2})
		RegionManager.page_count(@other_region, 2)
		sync(@other_region)

		assert page_ids(@other_region) == [1, 2]
		assert page_ids(@region) == [1]
	end

	test "all workers report page count" do
		start_manager(@region)
		RegionManager.subscribe(@region)

		RegionManager.page_started(@region, 1)
		RegionManager.page_result(@region, 1, :updated, %{pages: 3})
		RegionManager.page_count(@region, 3)
		sync(@region)

		for page <- 2..3, do: RegionManager.page_started(@region, page)
		for page <- 1..3, do: RegionManager.page_result(@region, page, :updated, %{pages: 3})

		assert_receive {:region_refresh_complete, summary}, 1_000
		assert summary.pages == 3
		assert summary.updated_pages == [1, 2, 3]
	end

	test "a cycle that never completes is reported as a failure" do
		start_manager(@region)
		RegionManager.subscribe(@region)

		RegionManager.page_started(@region, 1)
		RegionManager.page_result(@region, 1, :updated, %{pages: 2})
		RegionManager.page_started(@region, 2)

		assert_receive {:region_refresh_failed, summary}, 2_000
		assert summary.pages == 2
		assert summary.updated_pages == [1]
		assert %{page: 2, reason: :timeout} in summary.failures
	end

	test "heartbeat restarts a page worker that disappeared" do
		{:ok, manager} = RegionManager.start_link(@region, cycle_timeout: 5_000, heartbeat_ms: 50)
		on_exit(fn -> stop_region(@region) end)

		RegionManager.page_count(@region, 2)
		:sys.get_state(manager)
		assert page_ids(@region) == [1, 2]

		original = page_worker(@region, 2)
		GenServer.stop(original, :normal)

		replacement = await_replacement(@region, 2, original)
		assert is_pid(replacement)
		assert Process.alive?(replacement)
	end

	defp start_manager(region) do
		{:ok, manager} = RegionManager.start_link(region, cycle_timeout: 1_000)
		on_exit(fn -> stop_region(region) end)
		manager
	end

	defp stop_region(region) do
		for page <- 1..8, {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, region, page}) do
			try do
				GenServer.stop(pid, :normal)
			catch
				:exit, _ -> :ok
			end
		end

		for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:region, region}) do
			try do
				GenServer.stop(pid, :normal)
			catch
				:exit, _ -> :ok
			end
		end
	end

	defp sync(region) do
		[{pid, _}] = Registry.lookup(Marketmailer.Registry, {:region, region})
		:sys.get_state(pid)
	end

	defp page_ids(region) do
		for page <- 1..8, Registry.lookup(Marketmailer.Registry, {:page, region, page}) != [], do: page
	end

	# terminate_child/2 returns once the worker exits, but the Registry removes
	# its entry asynchronously; poll until the registry reflects the page set.
	defp await_pages(region, expected, attempts \\ 100) do
		case page_ids(region) do
			^expected ->
				expected

			ids ->
				if attempts <= 0 do
					ids
				else
					Process.sleep(10)
					await_pages(region, expected, attempts - 1)
				end
		end
	end

	defp page_worker(region, page) do
		[{pid, _}] = Registry.lookup(Marketmailer.Registry, {:page, region, page})
		pid
	end

	# The registry drops a dead worker's entry asynchronously, so a replacement is
	# only identifiable by a different pid than the one that was stopped.
	defp await_replacement(region, page, original, attempts \\ 100) do
		replacement =
			case Registry.lookup(Marketmailer.Registry, {:page, region, page}) do
				[{pid, _}] when pid != original -> pid
				_ -> nil
			end

		cond do
			is_pid(replacement) ->
				replacement

			attempts <= 0 ->
				nil

			true ->
				Process.sleep(10)
				await_replacement(region, page, original, attempts - 1)
		end
	end
end
