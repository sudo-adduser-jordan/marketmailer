defmodule Marketmailer.RegionManagerTest do
	# Per-page fan-out with no HTTP and no DB writes: ESI maintenance mode is
	# forced active so PageWorkers park on their 10s timer instead of fetching.
	use ExUnit.Case, async: false

	setup do
		ensure_ets(:esi_error_state)
		ensure_ets(:market_cache)

		# `mix test` boots the app, which already starts Registry and the
		# default coordinator (pollers stay disabled via `start_pollers: false`).
		# PageSup is a poller child, so tests provide it when absent.
		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		if !Process.whereis(Market.UpdateCoordinator) do
			start_supervised!({Market.UpdateCoordinator, []})
		end

		# Park every PageWorker: with maintenance active no worker calls ESI.
		:ets.insert(:esi_error_state, {:maintenance_mode, System.system_time(:millisecond) + 120_000})

		on_exit(fn ->
			:ets.delete(:esi_error_state, :maintenance_mode)
		end)

		:ok
	end

	test "page 1 reports its count and the manager fans out one worker per page" do
		region = 99_000_001
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		# Page 1 boots on init (parked, no fetch).
		assert [{_pid, _}] = Registry.lookup(Marketmailer.Registry, {:page, region, 1})

		# PageWorker 1 reports X-Pages -> manager provides workers for the rest.
		# `send` is fire-and-forget, so keep checking until the workers show up.
		send(manager, {:update_page_count, 3})
		assert_all_pages(region, [1, 2, 3])

		assert %{page_count: 3} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "shrinking page count stops the extra workers" do
		region = 99_000_002
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		send(manager, {:update_page_count, 3})
		assert_all_pages(region, [1, 2, 3])

		send(manager, {:update_page_count, 1})
		assert_no_pages(region, [2, 3])
		assert_all_pages(region, [1])

		assert %{page_count: 1} = :sys.get_state(manager)
		GenServer.stop(manager, :normal)
	end

	test "duplicate page count spawns nothing new" do
		region = 99_000_003
		{:ok, manager} = Marketmailer.RegionManager.start_link(region)

		before = DynamicSupervisor.count_children(Marketmailer.PageSup)
		send(manager, {:update_page_count, 1})
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

	defp ensure_ets(name) do
		case :ets.whereis(name) do
			:undefined -> :ets.new(name, [:named_table, :set, :public])
			_tid -> :ok
		end
	end
end
