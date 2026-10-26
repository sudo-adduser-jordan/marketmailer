defmodule ContractsTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	@round 42
	@now Contracts.now_ms()
	@future @now + 3_600_000

	@region 99_000_301
	@jita 30_000_142
	@tritanium 34
	@naglfar 19_720

	setup_all do
		await_repo!(Database, 10_000)

		Ecto.Migrator.run(
			Database,
			Database.Migrations.migrations_path(),
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

	test "contract tables exist" do
		%{rows: rows} = Database.query!("SELECT name FROM sqlite_master WHERE type = 'table'")
		tables = MapSet.new(rows, fn [name] -> name end)

		assert MapSet.member?(tables, "contracts")
		assert MapSet.member?(tables, "contract_items")
	end

	test "contracts exits" do
		assert :ok = Contracts.Database.upsert_page([contract(1_001), contract(1_002)], @region, 1, @round)

		assert Database.one(from c in "contracts", select: count(c.contract_id)) == 2

		assert Database.one(from c in "contracts", where: c.contract_id == 1_001, select: c.last_seen_round) ==
						 @round

		assert Database.one(from c in "contracts", where: c.contract_id == 1_001, select: c.region_id) ==
						 @region
	end

	test "contracts items exits" do
		seed([contract(1_001)])

		assert {:ok, _} =
						 Contracts.Database.replace_items(1_001, [
							 %{
								 "record_id" => 1_001_034,
								 "type_id" => @tritanium,
								 "quantity" => 10,
								 "is_included" => true,
								 "is_blueprint_copy" => false
							 }
						 ])

		assert Database.one(from i in "contract_items", where: i.contract_id == 1_001, select: count(i.record_id)) ==
						 1

		%{rows: [[fetched]]} =
			Database.query!("SELECT items_fetched FROM contracts WHERE contract_id = 1001")

		assert fetched in [1, "true"]
	end

	test "contracts types excluded" do
		config = Contracts.config()

		for type <- ~w(courier auction loan unknown) do
			refute Contracts.candidate?(esi_contract(type), config, @now)
		end

		assert Contracts.candidate?(esi_contract("item_exchange"), config, @now)
		refute Contracts.candidate?(esi_contract("item_exchange", %{"date_expired" => iso(@now - 1)}), config, @now)
		refute Contracts.candidate?(%{"type" => "item_exchange"}, config, @now)
		refute Contracts.candidate?(nil, config, @now)
	end

	test "captials are included in contracts" do
		seed_name(@tritanium, "Tritanium", 0)
		seed_name(@naglfar, "Naglfar", 1)

		seed_market([
			market_row(1, @tritanium, @jita, 1, 100.0),
			market_row(2, @naglfar, 30_000_144, 0, 2_000_000_000.0)
		])

		seed([contract(1_001)])
		seed_items(1_001, [{@tritanium, 1}, {@naglfar, 1}])

		assert [row] = Contracts.Database.top_desired(@round, 100, 0)
		assert row.contract_id == 1_001
		assert row.has_capital == 1
		assert row.item_count == 2
		assert row.items_value == 2_000_000_100.0
	end

	test "captials are valued at market average" do
		seed_name(@naglfar, "Naglfar", 1)

		seed_market([
			market_row(1, @naglfar, 30_000_144, 0, 2_000_000_000.0),
			market_row(2, @naglfar, 30_000_145, 0, 4_000_000_000.0),
			market_row(3, @naglfar, @jita, 1, 1_000_000_000.0)
		])

		seed([contract(1_001)])
		seed_items(1_001, [{@naglfar, 2}])

		assert [row] = Contracts.Database.top_desired(@round, 100, 0)
		assert row.items_value == 6_000_000_000.0
		assert row.has_capital == 1
	end

	test "thin top orders only fill their own depth" do
		seed_name(@tritanium, "Tritanium", 0)

		troll = %{market_row(1, @tritanium, @jita, 1, 1_197_600_000_000.0) | volume_remain: 1, volume_total: 1}
		real = %{market_row(2, @tritanium, @jita, 1, 500_000_000.0) | volume_remain: 100, volume_total: 100}
		seed_market([troll, real])

		seed([contract(1_001)])
		seed_items(1_001, [{@tritanium, 10}])

		assert [row] = Contracts.Database.top_desired(@round, 100, 0)
		assert row.items_value == 1_197_600_000_000.0 + 9 * 500_000_000.0
	end

	test "partial fills past total depth count only the fillable share" do
		seed_name(@tritanium, "Tritanium", 0)
		seed_market([market_row(1, @tritanium, @jita, 1, 100.0)])

		seed([contract(1_001)])
		seed_items(1_001, [{@tritanium, 200}])

		assert [row] = Contracts.Database.top_desired(@round, 100, 0)
		assert row.items_value == 100 * 100.0
	end

	test "requested items are subtracted from the margin" do
		seed_name(@tritanium, "Tritanium", 0)
		seed_market([market_row(1, @tritanium, @jita, 1, 100.0)])

		asks = %{market_row(2, @tritanium, @jita, 0, 120.0) | volume_remain: 100, volume_total: 100}
		seed_market([asks])

		seed([contract(1_001, %{"price" => 0})])
		Database.insert_all("contract_items", [item(1_001, @tritanium, 10, 1, 0)])

		Database.query!(
			"INSERT INTO contract_items (record_id, contract_id, type_id, quantity, is_included, is_blueprint_copy) VALUES (999001, 1001, #{@tritanium}, 5, 0, 0)"
		)

		assert [row] = Contracts.Database.top_desired(@round, 100, 0)
		assert row.items_value == 10 * 100.0
		assert row.margin == 10 * 100.0 - 5 * 120.0
	end

	test "contracts are filtered by margin" do
		seed_name(@tritanium, "Tritanium", 0)
		seed_market([market_row(1, @tritanium, @jita, 1, 100.0)])

		seed([
			contract(1_001, %{"price" => 0}),
			contract(1_002, %{"price" => 100}),
			contract(1_003, %{"price" => 1_000}),
			contract(1_004, %{"price" => 0})
		])

		seed_items(1_001, [{@tritanium, 1}])
		seed_items(1_002, [{@tritanium, 1}])
		seed_items(1_003, [{@tritanium, 10}])
		seed_items(1_004, [{@tritanium, 10}])

		assert Contracts.Database.top_desired(@round, 100, 100) |> Enum.map(& &1.contract_id) == [1_004, 1_001]
		assert Contracts.Database.top_desired(@round, 100, 1_001) == []
		assert Contracts.Database.top_desired(@round, 1, 0) |> Enum.map(& &1.contract_id) == [1_004]
		assert Contracts.Database.top_desired(@round + 1, 100, 0) == []
	end

	defp seed(contracts) do
		assert :ok = Contracts.Database.upsert_page(contracts, @region, 1, @round)
		Database.query!("UPDATE contracts SET items_fetched = 1")
		:ok
	end

	defp seed_items(contract_id, items) do
		rows = Enum.map(items, fn {type_id, quantity} -> item(contract_id, type_id, quantity, 1, 0) end)
		Database.insert_all("contract_items", rows)
	end

	defp seed_name(id, name, capital) do
		Database.insert_all("names", [%{id: id, name: name, is_capital_ship: capital}])
	end

	defp seed_market(rows), do: Database.insert_all("market", rows)

	defp esi_contract(type, overrides \\ %{}) do
		Map.merge(
			%{
				"contract_id" => 1_001,
				"type" => type,
				"title" => "",
				"price" => 0,
				"buyout" => nil,
				"date_expired" => iso(@future),
				"date_issued" => iso(@now)
			},
			overrides
		)
	end

	defp contract(contract_id, overrides \\ %{}) do
		Contracts.normalize(
			esi_contract("item_exchange", Map.merge(%{"contract_id" => contract_id}, overrides)),
			@region,
			1
		)
	end

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
