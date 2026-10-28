defmodule Marketmailer.PageWorkerGateTest do
	use ExUnit.Case, async: false

	alias Marketmailer.PageWorker
	alias Marketmailer.RegionManager

	@region 99_000_101

	setup_all do
		Ecto.Migrator.run(Database, Database.Migrations.migrations_path(), :up, all: true)
		:ok
	end

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)
		MarketmailerTest.Fixtures.ensure_ets(:esi_rate_state)
		MarketmailerTest.Fixtures.ensure_ets(:network_state, [:named_table, :set, :public, read_concurrency: true])

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

		# Park every worker by default and hold the maintenance ping, so a worker
		# only fetches when a test explicitly lets it through.
		MarketmailerTest.Fixtures.park_page_workers()
		:ets.insert(:esi_error_state, {:maintenance_ping, System.system_time(:millisecond) + 60_000})

		# Any watchdog probe already in flight must report the network up, or it
		# would flip the state back down after the reset below.
		:persistent_term.put({:marketmailer_test, :probe_result}, :ok)
		on_exit(fn -> :persistent_term.erase({:marketmailer_test, :probe_result}) end)

		MarketmailerTest.Fixtures.reset_network()

		test_pid = self()

		Application.put_env(:marketmailer, :esi_http_fun, fn url, _opts ->
			send(test_pid, {:http, url})
			{:ok, %Req.Response{status: 304, headers: %{"etag" => ["\"etag\""], "x-pages" => ["1"]}, body: ""}}
		end)

		on_exit(fn -> Application.delete_env(:marketmailer, :esi_http_fun) end)

		:ok
	end

	test "worker does not fetch when out of page count bounds" do
		manager = start_manager(@region)
		RegionManager.page_count(@region, 1)
		:sys.get_state(manager)

		worker = start_worker(manager, @region, 2)
		send(worker, :work)

		refute_receive {:http, _url}, 200
		refute Process.alive?(worker)
	end

	test "worker pauses when count is unknown" do
		manager = start_manager(@region)

		worker = start_worker(manager, @region, 2)
		send(worker, :work)

		refute_receive {:http, _url}, 200
		assert Process.alive?(worker)
		assert [{^worker, _}] = Registry.lookup(Marketmailer.Registry, {:page, @region, 2})
	end

	test "worker can pause" do
		manager = start_manager(@region)

		worker = start_worker(manager, @region, 2)

		for _ <- 1..3 do
			send(worker, :work)
			refute_receive {:http, _url}, 50
		end

		assert Process.alive?(worker)
		assert [{^worker, _}] = Registry.lookup(Marketmailer.Registry, {:page, @region, 2})
	end

	test "worker pauses while the esi is down" do
		manager = start_manager(@region)
		worker = page_worker(@region, 1)

		:ets.insert(:esi_error_state, {:maintenance_mode, System.system_time(:millisecond) + 60_000})
		send(worker, :work)

		refute_receive {:http, _url}, 200
		assert Process.alive?(worker)
		assert :sys.get_state(manager).started == MapSet.new()
	end

	test "worker pauses while the network is down" do
		:ets.delete(:esi_error_state, :maintenance_mode)
		MarketmailerTest.Fixtures.network_down()

		manager = start_manager(@region)
		worker = page_worker(@region, 1)

		send(worker, :work)

		refute_receive {:http, _url}, 200
		assert Process.alive?(worker)
		assert :sys.get_state(manager).started == MapSet.new()
	end

	test "worker resumes fetching" do
		:ets.delete(:esi_error_state, :maintenance_mode)
		MarketmailerTest.Fixtures.network_down()

		start_manager(@region)
		worker = page_worker(@region, 1)

		send(worker, :work)
		refute_receive {:http, _url}, 200

		MarketmailerTest.Fixtures.reset_network()
		send(worker, :work)

		assert_receive {:http, url}, 1_000
		assert url =~ "markets/#{@region}/orders/?page=1"
	end

	test "a raised request pauses instead of killing the worker" do
		MarketmailerTest.Fixtures.reset_esi_maintenance()
		MarketmailerTest.Fixtures.reset_network()

		Application.put_env(:marketmailer, :esi_http_fun, fn _url, _opts ->
			raise "Finch was unable to provide a connection within the timeout due to excess queuing"
		end)

		manager = start_manager(@region)
		_ = manager
		RegionManager.subscribe(@region)
		worker = page_worker(@region, 1)

		log =
			ExUnit.CaptureLog.capture_log(fn ->
				send(worker, :work)
				Process.sleep(200)
			end)

		assert Process.alive?(worker)
		# Pool saturation backs this worker off on its own; it no longer parks
		# the whole fleet behind a maintenance gate.
		refute ESI.Maintenance.down?()
		assert log =~ "page_fetch_error"

		assert_receive {:region_refresh_failed, summary}, 1_000
		assert %{page: 1, reason: :request_failed} in summary.failures
	end

	defp start_manager(region) do
		{:ok, manager} = RegionManager.start_link(region, cycle_timeout: 1_000)

		on_exit(fn ->
			for page <- 1..8, {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, region, page}) do
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

	defp start_worker(manager, region, page) do
		{:ok, worker} = PageWorker.start_link({manager, region, page})

		on_exit(fn ->
			try do
				GenServer.stop(worker, :normal)
			catch
				:exit, _ -> :ok
			end
		end)

		worker
	end

	defp page_worker(region, page) do
		[{pid, _}] = Registry.lookup(Marketmailer.Registry, {:page, region, page})
		pid
	end
end
