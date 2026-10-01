defmodule Marketmailer.RegionManagerTest do
	# Sequential per-region sweep with stubbed ESI: no HTTP, no DB writes.
	use ExUnit.Case, async: false

	setup do
		ensure_ets(:esi_error_state)
		registry = :"rm_registry_#{System.unique_integer([:positive])}"

		# RegionManager hardcodes Marketmailer.Registry; point it at a fresh one
		# by starting the expected name only if absent.
		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		_ = registry
		coord = :"rm_coord_#{System.unique_integer([:positive])}"
		start_supervised!({Market.UpdateCoordinator, name: coord, cycle_timeout: 2_000})
		:ok = Market.UpdateCoordinator.subscribe(self(), coord)
		{:ok, coord: coord}
	end

	test "sweeps pages 1..N sequentially with one worker", %{coord: coord} do
		region = 99_000_001
		test_pid = self()

		fetch_fun = fn
			^region, 1 ->
				{:ok, [], %{url: "stub://#{region}/1", etag: nil, ttl: 60_000, pages: 3, retry_after_ms: 0}}

			^region, page ->
				send(test_pid, {:fetched, page})
				{:not_modified, %{url: "stub://#{region}/#{page}", etag: nil, ttl: 60_000, pages: 3, retry_after_ms: 0}}
		end

		persist_fun = fn _page, _ctx -> :ok end
		name = {:via, Registry, {Marketmailer.Registry, {:region, region}}}
		assert Registry.lookup(Marketmailer.Registry, {:region, region}) == []

		{:ok, pid} =
			GenServer.start_link(
				Marketmailer.RegionManager,
				{region, [fetch_fun: fetch_fun, persist_fun: persist_fun, coordinator: coord]},
				name: name
			)

		send(pid, :work)

		assert_receive {:fetched, 2}, 1_000
		assert_receive {:fetched, 3}, 1_000
		assert_receive {:region_refresh_complete, %{region: ^region, pages: 3}}, 1_000
		assert Process.alive?(pid)
		GenServer.stop(pid, :normal)
	end

	test "a persist crash still reports failure instead of hanging the cycle", %{coord: coord} do
		region = 99_000_002

		fetch_fun = fn ^region, 1 ->
			{:ok, [], %{url: "stub://#{region}/1", etag: nil, ttl: 60_000, pages: 1, retry_after_ms: 0}}
		end

		persist_fun = fn _page, _ctx -> raise "boom" end

		{:ok, pid} =
			GenServer.start_link(
				Marketmailer.RegionManager,
				{region, [fetch_fun: fetch_fun, persist_fun: persist_fun, coordinator: coord]},
				name: {:via, Registry, {Marketmailer.Registry, {:region, region}}}
			)

		send(pid, :work)
		assert_receive {:region_refresh_failed, %{region: ^region}}, 1_000
		assert Process.alive?(pid)
		GenServer.stop(pid, :normal)
	end

	defp ensure_ets(name) do
		case :ets.whereis(name) do
			:undefined -> :ets.new(name, [:named_table, :set, :public])
			_tid -> :ok
		end
	end
end
