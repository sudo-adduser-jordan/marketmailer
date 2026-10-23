defmodule ContractsTest do
	use ExUnit.Case, async: false

	@round 42
	@now Contracts.now_ms()
	@future @now + 3_600_000

	setup_all do
		await_repo!(Database, 10_000)

		Ecto.Migrator.run(
			Database,
			Path.join(:code.priv_dir(:marketmailer), "repo/migrations"),
			:up,
			all: true
		)

		if :ets.whereis(:market_cache) == :undefined do
			:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		end

		if :ets.whereis(:esi_error_state) == :undefined do
			:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])
		end

		if :ets.whereis(:esi_rate_state) == :undefined do
			:ets.new(:esi_rate_state, [:named_table, :set, :public, read_concurrency: true])
		end

		:ok
	end

	setup do
		Database.delete_all("contract_items")
		Database.delete_all("contracts")
		Database.delete_all("market")
		Database.delete_all("names")
		Database.delete_all("regions")

		:persistent_term.erase({Contracts, :top_round})
		:persistent_term.erase({Contracts, :round_stats})
		MarketmailerTest.Fixtures.reset_network()

		on_exit(fn ->
			Database.delete_all("contract_items")
			Database.delete_all("contracts")
			Database.delete_all("market")
			Database.delete_all("names")
			Database.delete_all("regions")
			:persistent_term.erase({Contracts, :top_round})
			:persistent_term.erase({Contracts, :round_stats})
			MarketmailerTest.Fixtures.reset_network()
		end)

		:ok
	end

	test "filters excluded contract types and expired contracts" do
		config = Contracts.config()

		assert Contracts.candidate?(
						 %{
							 "contract_id" => 1,
							 "type" => "item_exchange",
							 "date_expired" => iso(@future)
						 },
						 config,
						 @now
					 )

		refute Contracts.candidate?(
						 %{
							 "contract_id" => 2,
							 "type" => "courier",
							 "date_expired" => iso(@future)
						 },
						 config,
						 @now
					 )

		refute Contracts.candidate?(
						 %{
							 "contract_id" => 3,
							 "type" => "item_exchange",
							 "date_expired" => iso(@now - 1_000)
						 },
						 config,
						 @now
					 )

		dt = DateTime.from_unix!(@future, :millisecond)
		assert Contracts.parse_iso(DateTime.to_iso8601(dt)) == @future
	end

	test "persists a page, claims item work once, and drops a deleted contract" do
		contract = %{
			contract_id: 10,
			region_id: 91_000_001,
			page: 1,
			type: "item_exchange",
			title: "A contract",
			price: 10_000_000.0,
			buyout: nil,
			reward: nil,
			collateral: nil,
			volume: 1.0,
			expires_at: @future,
			issued_at: @now,
			days_to_complete: nil,
			start_location_id: 60_000_001,
			end_location_id: nil,
			issuer_id: 1,
			issuer_corporation_id: 2
		}

		assert :ok = Contracts.Database.upsert_page([contract], 91_000_001, 1, @round)

		assert Contracts.Database.max_known_page(91_000_001) == 1

		assert Contracts.Database.item_candidates(91_000_001, 1, @round, Contracts.config(), @now) ==
						 [%{contract_id: 10, items_attempts: 0}]

		assert Contracts.Database.claim_item(10, @round)
		refute Contracts.Database.claim_item(10, @round)

		assert {:ok, _} =
						 Contracts.Database.replace_items(10, [
							 %{
								 "record_id" => 100,
								 "type_id" => 34,
								 "quantity" => 5,
								 "is_included" => true,
								 "is_blueprint_copy" => false
							 }
						 ])

		assert Contracts.Database.item_candidates(91_000_001, 1, @round, Contracts.config(), @now) ==
						 []

		assert Contracts.Database.claim_item(11, @round) == false

		assert {:ok, _} = Contracts.Database.drop_contract(10)
		assert Database.query!("SELECT COUNT(*) FROM contracts").rows == [[0]]
		assert Database.query!("SELECT COUNT(*) FROM contract_items").rows == [[0]]
	end

	test "values capital hulls at the all-region sell average and keeps only 100m+ margins" do
		Database.insert_all("names", [
			%{id: 34, name: "Tritanium", is_capital_ship: 0},
			%{id: 23_773, name: "Archon", is_capital_ship: 1},
			%{id: 60_000_001, name: "Jita", is_capital_ship: 0}
		])

		Database.insert_all("regions", [%{region_id: 91_000_001, name: "The Forge"}])

		Database.insert_all("market", [
			market_row(1, 34, 30_000_142, 1, 200_000_000.0),
			market_row(2, 34, 30_000_001, 0, 900_000_000.0),
			market_row(3, 23_773, 30_000_001, 0, 1_000_000_000.0),
			market_row(4, 23_773, 30_000_002, 0, 2_000_000_000.0),
			market_row(5, 23_773, 30_000_142, 1, 1.0)
		])

		base = %{
			region_id: 91_000_001,
			page: 1,
			type: "item_exchange",
			title: "Fit",
			price: 100_000_000.0,
			buyout: nil,
			reward: nil,
			collateral: nil,
			volume: 1.0,
			expires_at: @future,
			issued_at: @now,
			days_to_complete: nil,
			start_location_id: 60_000_001,
			end_location_id: nil,
			issuer_id: 1,
			issuer_corporation_id: 2,
			items_fetched: 1,
			items_attempts: 0,
			items_next_attempt_at: 0,
			items_claim_round: 0,
			last_seen_round: @round,
			inserted_at: NaiveDateTime.utc_now(:second),
			updated_at: NaiveDateTime.utc_now(:second)
		}

		Database.insert_all("contracts", [
			Map.merge(base, %{contract_id: 1, title: "Capital + item"}),
			Map.merge(base, %{contract_id: 2, price: 1_000_000.0, title: "No sell wall"}),
			Map.merge(base, %{contract_id: 3, price: 0.0, title: "BPC only"}),
			Map.merge(base, %{contract_id: 4, price: 50_000_000.0, title: "Item only"}),
			Map.merge(base, %{contract_id: 5, title: "Old round", last_seen_round: @round - 1}),
			Map.merge(base, %{contract_id: 6, title: "Expired", expires_at: @now - 1_000}),
			Map.merge(base, %{contract_id: 7, price: 100_000_000.0, title: "Exactly 100m"})
		])

		Database.insert_all("contract_items", [
			item(1, 34, 1, 1, 0),
			item(1, 23_773, 1, 1, 0),
			item(2, 999_999, 1, 1, 0),
			item(3, 34, 1, 1, 1),
			item(4, 34, 1, 1, 0),
			item(5, 34, 1, 1, 0),
			item(6, 34, 1, 1, 0),
			item(7, 34, 1, 1, 0)
		])

		config = Contracts.config()

		top = Contracts.Database.top_desired(@round, 100, Keyword.fetch!(config, :min_margin))

		assert Enum.map(top, & &1.contract_id) == [1, 4, 7]
		[capital, item_only, threshold] = top

		assert capital.items_value == 1_700_000_000.0
		assert capital.margin == 1_600_000_000.0
		assert capital.has_capital == 1
		assert capital.item_count == 2
		assert capital.region_name == "The Forge"
		assert capital.location_name == "Jita"

		assert item_only.items_value == 200_000_000.0
		assert item_only.margin == 150_000_000.0
		assert item_only.has_capital == 0
		assert threshold.margin == 100_000_000.0

		assert Enum.sort(Contracts.Database.item_names([1, 4])[1]) == ["Archon", "Tritanium"]
	end

	test "paginates the top 100 into ten-row pages with prev/next buttons" do
		contracts =
			for id <- 1..25 do
				%{
					contract_id: id,
					title: "Contract #{id}",
					region_name: "The Forge",
					location_name: "Jita",
					price: 1_000_000.0,
					buyout: nil,
					items_value: 201_000_000.0,
					margin: 200_000_000.0,
					item_count: 1,
					item_names: ["Tritanium"],
					has_capital: 0,
					expires_at: @future
				}
			end

		config = Contracts.config(broadcast_per_page: 10, broadcast_limit: 100)

		page1 = Contracts.Embeds.page_payload(contracts, 1, config)
		[embed1] = page1.embeds
		assert embed1.title == "Contract arbitrage (1/3)"
		assert length(String.split(embed1.description, "\n")) == 10
		assert [%{components: [prev, next]}] = page1.components
		assert prev.disabled == true
		assert next.disabled == false
		assert next.custom_id == "contract_list:page:2"

		page3 = Contracts.Embeds.page_payload(contracts, 99, config)
		[embed3] = page3.embeds
		assert embed3.title == "Contract arbitrage (3/3)"
		assert length(String.split(embed3.description, "\n")) == 5
		assert [%{components: [prev, next]}] = page3.components
		assert prev.disabled == false
		assert next.disabled == true
		assert prev.custom_id == "contract_list:page:2"
	end

	test "a single page has no pagination components" do
		payload = Contracts.Embeds.page_payload([], 1, Contracts.config())
		assert payload.components == []
		assert [%{title: "Contract arbitrage"}] = payload.embeds
	end

	test "item gate caps concurrency and frees a slot when a holder dies" do
		previous = Application.get_env(:marketmailer, :contracts, [])

		Application.put_env(:marketmailer, :contracts, item_concurrency: 2)

		on_exit(fn ->
			if previous do
				Application.put_env(:marketmailer, :contracts, previous)
			else
				Application.delete_env(:marketmailer, :contracts)
			end
		end)

		{:ok, gate} = Contracts.ItemGate.start_link()
		parent = self()

		holder = fn tag ->
			pid =
				spawn(fn ->
					Contracts.ItemGate.run(fn ->
						send(parent, {:held, tag})
						Process.sleep(:infinity)
					end)
				end)

			on_exit(fn -> Process.exit(pid, :kill) end)
			pid
		end

		first = holder.(1)
		assert_receive {:held, 1}, 1_000
		holder.(2)
		assert_receive {:held, 2}, 1_000
		assert map_size(:sys.get_state(gate).active) == 2

		waiter = spawn(fn -> Contracts.ItemGate.run(fn -> send(parent, :third) end) end)
		on_exit(fn -> Process.exit(waiter, :kill) end)
		refute_receive :third, 100

		Process.exit(first, :kill)
		assert_receive :third, 1_000
	end

	test "manager dispatches at most four regions at once" do
		regions = [91_000_011, 91_000_012, 91_000_013, 91_000_014, 91_000_015]
		key = {Marketmailer.RegionManagerSupervisor, :region_ids}
		old = :persistent_term.get(key, [])

		previous = Application.get_env(:marketmailer, :contracts, [])
		Application.put_env(:marketmailer, :contracts, initial_delay_ms: 3_600_000, region_concurrency: 4)

		:persistent_term.put(key, regions)

		fakes =
			for id <- regions do
				{:ok, pid} =
					GenServer.start_link(
						ContractsTest.FakeRegion,
						{id, self()},
						name: {:via, Registry, {Marketmailer.Registry, {:contract_region, id}}}
					)

				{id, pid}
			end

		{:ok, manager} = Contracts.Manager.start_link()
		send(manager, :start_round)

		started = collect_starts(4)
		assert Enum.sort(Enum.map(started, &elem(&1, 1))) == Enum.sort(Enum.take(regions, 4))
		refute_receive {:started, 91_000_015, _}, 100

		round = started |> hd() |> elem(2)

		Contracts.Manager.region_complete(round, %{
			region: 91_000_011,
			round: round,
			pages: 1,
			updated_pages: [1],
			failures: [],
			item_fetches: 0,
			item_failures: 0,
			dropped: 0
		})

		assert_receive {:started, 91_000_015, ^round}, 1_000

		GenServer.stop(manager)

		Enum.each(fakes, fn {_id, pid} -> GenServer.stop(pid) end)

		if previous do
			Application.put_env(:marketmailer, :contracts, previous)
		else
			Application.delete_env(:marketmailer, :contracts)
		end

		:persistent_term.put(key, old)
		:persistent_term.erase({Contracts, :active_round})
	end

	test "defers a rate-limited item without counting an attempt" do
		contract = %{
			contract_id: 20,
			region_id: 91_000_007,
			page: 1,
			type: "item_exchange",
			title: "Deferred",
			price: 1_000_000.0,
			buyout: nil,
			reward: nil,
			collateral: nil,
			volume: 1.0,
			expires_at: @future,
			issued_at: @now,
			days_to_complete: nil,
			start_location_id: nil,
			end_location_id: nil,
			issuer_id: 1,
			issuer_corporation_id: 2
		}

		assert :ok = Contracts.Database.upsert_page([contract], 91_000_007, 1, @round)
		_ = Contracts.Database.defer_item(20, 5_000)

		assert %{rows: [[0, next_attempt, 0]]} =
						 Database.query!(
							 "SELECT items_attempts, items_next_attempt_at, items_claim_round FROM contracts WHERE contract_id = 20",
							 []
						 )

		assert next_attempt >= Contracts.now_ms() + 4_000
	end

	test "a rate-limited page is retried within the round" do
		region = 91_000_008
		{:ok, _} = Registry.register(Marketmailer.Registry, {:contract_page, region, 1}, nil)
		{:ok, manager} = Contracts.RegionManager.start_link(region)

		Contracts.RegionManager.start_round(region, @round)
		assert_receive {:"$gen_cast", {:run_round, @round}}, 1_000

		Contracts.RegionManager.page_result(region, @round, 1, :rate_limited, %{retry_after_ms: 1_000})
		assert_receive {:"$gen_cast", {:run_round, @round}}, 2_000

		GenServer.stop(manager)
	end

	test "manager pauses contract rounds while the network is down" do
		region = 91_000_021
		key = {Marketmailer.RegionManagerSupervisor, :region_ids}
		old = :persistent_term.get(key, [])

		previous = Application.get_env(:marketmailer, :contracts, [])

		Application.put_env(:marketmailer, :contracts,
			initial_delay_ms: 3_600_000,
			region_concurrency: 1,
			pause_recheck_ms: 3_600_000
		)

		:persistent_term.put(key, [region])

		{:ok, fake} =
			GenServer.start_link(
				ContractsTest.FakeRegion,
				{region, self()},
				name: {:via, Registry, {Marketmailer.Registry, {:contract_region, region}}}
			)

		MarketmailerTest.Fixtures.network_down()

		{:ok, manager} = Contracts.Manager.start_link()
		send(manager, :start_round)

		refute_receive {:started, ^region, _round}, 250
		assert %{round: nil, paused: true} = :sys.get_state(manager)

		Marketmailer.Maintenance.report_connected()
		send(manager, {:maintenance, :up})

		assert_receive {:started, ^region, _round}, 1_000

		GenServer.stop(manager)
		GenServer.stop(fake)

		if previous do
			Application.put_env(:marketmailer, :contracts, previous)
		else
			Application.delete_env(:marketmailer, :contracts)
		end

		:persistent_term.put(key, old)
		:persistent_term.erase({Contracts, :active_round})
	end

	test "a contract page worker fetches nothing while the network is down" do
		region = 91_000_022
		page = 1
		test_pid = self()
		previous = Application.get_env(:marketmailer, :esi_http_fun)

		Application.put_env(:marketmailer, :esi_http_fun, fn url, _opts ->
			send(test_pid, {:fetched, url})
			{:ok, %{status: 200, headers: %{"x-pages" => ["1"]}, body: "[]"}}
		end)

		on_exit(fn ->
			if previous do
				Application.put_env(:marketmailer, :esi_http_fun, previous)
			else
				Application.delete_env(:marketmailer, :esi_http_fun)
			end
		end)

		MarketmailerTest.Fixtures.network_down()

		{:ok, worker} = Contracts.PageWorker.start_link({region, page})
		Contracts.PageWorker.run_round(region, page, @round)

		refute_receive {:fetched, _url}, 200
		assert Process.alive?(worker)

		GenServer.stop(worker)
	end

	defp collect_starts(count), do: Enum.map(1..count, fn _ -> assert_receive({:started, _id, _round}, 1_000) end)

	defp await_repo!(repo, timeout) do
		deadline = System.monotonic_time(:millisecond) + timeout
		await_repo_loop!(repo, deadline)
	end

	defp await_repo_loop!(repo, deadline) do
		_ = repo.query!("SELECT 1")
		:ok
	rescue
		_ ->
			if System.monotonic_time(:millisecond) > deadline do
				flunk("test repo #{inspect(repo)} did not come up")
			else
				Process.sleep(20)
				await_repo_loop!(repo, deadline)
			end
	end

	defp iso(ms), do: DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()

	defp market_row(id, type_id, system_id, is_buy_order, price) do
		%{
			order_id: id,
			duration: 90,
			is_buy_order: is_buy_order,
			issued: iso(@now),
			location_id: 60_000_001,
			min_volume: 1,
			price: price,
			range: "station",
			system_id: system_id,
			type_id: type_id,
			volume_remain: 100,
			volume_total: 100,
			inserted_at: NaiveDateTime.utc_now(:second),
			updated_at: NaiveDateTime.utc_now(:second)
		}
	end

	defp item(contract_id, type_id, quantity, is_included, is_blueprint_copy) do
		%{
			record_id: contract_id * 1_000 + type_id,
			contract_id: contract_id,
			type_id: type_id,
			quantity: quantity,
			is_included: is_included,
			is_blueprint_copy: is_blueprint_copy
		}
	end
end

defmodule ContractsTest.FakeRegion do
	use GenServer

	def init({id, test_pid}), do: {:ok, %{id: id, test_pid: test_pid}}

	def handle_cast({:start_round, round}, state) do
		send(state.test_pid, {:started, state.id, round})
		{:noreply, state}
	end
end
