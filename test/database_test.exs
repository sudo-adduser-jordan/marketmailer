defmodule Etag.ExpiryTest do
	use ExUnit.Case, async: false

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

		:ok
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

	test "database exists" do
		assert %{rows: [[1]]} = Database.query!("SELECT 1")
		assert File.exists?(Database.config()[:database])
	end

	test "database tables exist" do
		%{rows: rows} = Database.query!("SELECT name, type FROM sqlite_master")

		objects = MapSet.new(rows, fn [name, _type] -> name end)

		for object <- ~w(market etags names systems discord schema_migrations marketListView) do
			assert MapSet.member?(objects, object), "missing #{object}"
		end
	end

	test "etag expires" do
		url = "https://esi.evetech.net/v1/markets/990000/orders/?page=1"
		on_exit(fn -> :ets.delete(:market_cache, url) end)

		now = System.system_time(:millisecond)

		:ets.delete(:market_cache, url)
		assert Etag.Database.resume_delay_ms(url) == 0

		:ets.insert(:market_cache, {url, "\"v1\"", now + 5_000})
		delay = Etag.Database.resume_delay_ms(url)
		assert delay > 0
		assert delay <= 5_000

		:ets.insert(:market_cache, {url, "\"v1\"", now - 1})
		assert Etag.Database.resume_delay_ms(url) == 0

		:ets.insert(:market_cache, {url, "\"v1\"", now + 3_600_000})
		assert Etag.Database.resume_delay_ms(url) == 0
	end
end

defmodule Market.DatabaseTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Database
	alias Market.Database, as: MarketDatabase

	@jita 30_000_142
	@jita_station 60_003_760
	@tritanium 34
	@plex 44_992
	@naglfar 19_720

	setup_all do
		Ecto.Migrator.run(
			Database,
			Database.Migrations.migrations_path(),
			:up,
			all: true
		)

		:ok
	end

	setup do
		Database.delete_all("market")
		Database.delete_all("names")
		Database.delete_all("systems")
		Database.delete_all("discord")
		Database.delete_all("contract_items")
		Database.delete_all("contracts")
		:ok
	end

	test "database exists" do
		assert %{rows: [[1]]} = Database.query!("SELECT 1")
		assert File.exists?(Database.config()[:database])
	end

	test "database tables exist" do
		%{rows: rows} = Database.query!("SELECT name, type FROM sqlite_master")

		objects = MapSet.new(rows, fn [name, _type] -> name end)

		for object <- ~w(market etags names systems discord schema_migrations marketListView) do
			assert MapSet.member?(objects, object), "missing #{object}"
		end
	end

	test "case-insensitive match" do
		seed_names()

		MarketDatabase.upsert_orders([
			order(%{"order_id" => 1, "is_buy_order" => true, "price" => 100.0}),
			order(%{"order_id" => 2, "price" => 50.0})
		])

		assert %MarketView{item_name: "Tritanium"} = MarketDatabase.get_market_item("tritanium")
		assert %MarketView{item_name: "Tritanium"} = MarketDatabase.get_market_item("  TRITANIUM  ")
		assert %MarketView{item_name: "Tritanium"} = MarketDatabase.get_market_item("trita")
		assert MarketDatabase.get_market_item("") == nil
		assert MarketDatabase.get_market_item(nil) == nil
	end

	test "PLEX exists" do
		seed_names()
		Database.insert_all("names", [%{id: @plex, name: "PLEX", is_capital_ship: 0}])

		MarketDatabase.upsert_orders([
			order(%{
				"order_id" => 11,
				"type_id" => @plex,
				"is_buy_order" => true,
				"price" => 5_000_000.0
			}),
			order(%{"order_id" => 12, "type_id" => @plex, "price" => 4_900_000.0})
		])

		row = MarketDatabase.get_market_item("plex")

		assert %MarketView{item_name: "PLEX"} = row
		assert row.buy_price == 5_000_000.0
		assert row.instant_sell_profit == 1_000_000.0
	end

	test "npc owned structures exist" do
		seed_names()

		MarketDatabase.upsert_orders([
			order(%{"order_id" => 21, "is_buy_order" => true, "price" => 20.0}),
			order(%{"order_id" => 22, "price" => 10.0})
		])

		assert %MarketView{location_name: "Jita IV - Moon 4 - Caldari Navy Assembly Plant"} =
						 MarketDatabase.get_market_item("tritanium")
	end

	test "player owned structures do not exists" do
		seed_names()
		player_structure = 1_030_000_000_001

		MarketDatabase.upsert_orders([
			order(%{"order_id" => 23, "is_buy_order" => true, "price" => 20.0}),
			order(%{
				"order_id" => 24,
				"price" => 10.0,
				"location_id" => player_structure,
				"system_id" => 30_000_142
			})
		])

		rows = MarketDatabase.get_items_less_than_jita_buy()

		assert Enum.any?(rows, fn row -> row.location_name == "Player Station" end)
		assert MarketDatabase.get_market_item("tritanium") == nil
	end

	test "Jita buy-wall does not contain captials" do
		seed_names()
		Database.insert_all("names", [%{id: @naglfar, name: "Naglfar", is_capital_ship: 1}])

		MarketDatabase.upsert_orders([
			order(%{
				"order_id" => 31,
				"type_id" => @naglfar,
				"is_buy_order" => true,
				"price" => 3_000_000_000.0,
				"volume_remain" => 1
			}),
			order(%{
				"order_id" => 32,
				"type_id" => @naglfar,
				"price" => 2_000_000_000.0,
				"system_id" => 30_000_144,
				"volume_remain" => 1
			}),
			order(%{"order_id" => 33, "is_buy_order" => true, "price" => 100.0}),
			order(%{"order_id" => 34, "price" => 50.0, "system_id" => 30_000_144})
		])

		assert [%MarketView{item_name: "Tritanium"} | _] = MarketDatabase.get_best_order()
		refute Enum.any?(MarketDatabase.get_items_less_than_jita_buy(), fn row -> row.item == "Naglfar" end)
	end

	test "stat command is valid" do
		seed_names()
		MarketDatabase.upsert_orders([order(%{"order_id" => 41})])

		assert {:ok, stats} = MarketDatabase.get_database_stats()

		assert stats.order_count == 1
		assert stats.sell_orders == 1
		assert stats.buy_orders == 0
		assert stats.tracked_types == 1
		assert stats.tracked_systems == 1
		assert stats.known_names == 3
		assert stats.known_systems == 1
		assert is_integer(stats.schema_version)
		assert is_binary(stats.journal_mode)
	end

	test "orders are updated in batches" do
		assert MarketDatabase.upsert_chunk_size() == 1_000

		url = "https://esi.evetech.net/v1/markets/990001/orders/?page=1"
		count = MarketDatabase.upsert_chunk_size() + 200

		orders =
			for index <- 1..count do
				order(%{"order_id" => 100_000 + index, "price" => 10.0})
			end

		assert MarketDatabase.upsert_orders(orders, url) == count
		assert market_count() == count

		changed = List.replace_at(orders, 0, order(%{"order_id" => 100_001, "price" => 11.0}))

		assert MarketDatabase.upsert_orders(changed, url) == 1
		assert Database.one(from m in "market", where: m.order_id == 100_001, select: m.price) == 11.0
		assert market_count() == count
	end

	test "orders that do not exist are removed" do
		url = "https://esi.evetech.net/v1/markets/990002/orders/?page=1"

		MarketDatabase.upsert_orders(
			[order(%{"order_id" => 51}), order(%{"order_id" => 52})],
			url
		)

		assert market_count() == 2

		MarketDatabase.upsert_orders([order(%{"order_id" => 51})], url)

		assert market_count() == 1
		assert Database.one(from m in "market", where: m.order_id == 51, select: count(m.order_id)) == 1
	end

	test "orders have an etag" do
		url = "https://esi.evetech.net/v1/markets/990003/orders/?page=1"
		expires_at = System.system_time(:millisecond) + 60_000

		on_exit(fn ->
			Database.delete_all(from e in "etags", where: e.url == ^url)
			:ets.delete(:market_cache, url)
		end)

		MarketDatabase.upsert_orders([order(%{"order_id" => 61})], url)

		assert Database.one(from m in "market", where: m.order_id == 61, select: m.url) == url

		assert Etag.Database.upsert_etag(url, "\"v1\"", expires_at) == :ok
		assert Etag.Database.get_etag(url) == "\"v1\""
		assert Etag.Database.get_expiry(url) == expires_at
		assert Database.one(from e in "etags", where: e.url == ^url, select: e.etag) == "\"v1\""
	end

	test "all orders successfuly write to database" do
		seed_names()
		url = "https://esi.evetech.net/v1/markets/990004/orders/?page=1"

		orders =
			for index <- 1..500 do
				order(%{"order_id" => 200_000 + index, "price" => index * 1.0, "volume_remain" => index})
			end

		assert MarketDatabase.upsert_orders(orders, url) == 500
		assert market_count() == 500

		assert Database.one(from m in "market", where: m.order_id == 200_123, select: m.price) == 123.0

		assert Database.one(from m in "market", where: m.order_id == 200_123, select: m.volume_remain) ==
						 123
	end

	defp market_count do
		Database.one(from m in "market", select: count(m.order_id))
	end

	defp seed_names do
		Database.insert_all("names", [
			%{id: @tritanium, name: "Tritanium", is_capital_ship: 0},
			%{id: @jita_station, name: "Jita IV - Moon 4 - Caldari Navy Assembly Plant", is_capital_ship: 0},
			%{id: @jita, name: "Jita", is_capital_ship: 0}
		])

		Database.insert_all("systems", [
			%{system_id: @jita, name: "Jita", security_status: 0.9, region_name: "The Forge"}
		])
	end

	defp order(overrides) do
		Map.merge(
			%{
				"order_id" => 1,
				"duration" => 90,
				"is_buy_order" => false,
				"issued" => "2026-10-20T00:00:00Z",
				"location_id" => @jita_station,
				"min_volume" => 1,
				"price" => 10.0,
				"range" => "station",
				"system_id" => @jita,
				"type_id" => @tritanium,
				"volume_remain" => 10,
				"volume_total" => 10
			},
			overrides
		)
	end
end

defmodule Database.WriterTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Market.Database, as: MarketDatabase

	@base_order_id 9_000_000_000

	setup_all do
		Ecto.Migrator.run(
			Database,
			Database.Migrations.migrations_path(),
			:up,
			all: true
		)

		:ok
	end

	setup do
		on_exit(fn -> Database.delete_all(from(m in "market", where: m.order_id >= @base_order_id)) end)
		:ok
	end

	test "a burst of page writes all succeeds with no timeouts" do
		burst = 40
		per_page = 25

		results =
			1..burst
			|> Task.async_stream(
				fn index ->
					url = "https://esi.evetech.net/v1/markets/99#{index}/orders/?page=1"

					MarketDatabase.upsert_orders(
						page_fixture(@base_order_id + index * per_page, per_page),
						url
					)
				end,
				max_concurrency: burst,
				timeout: 30_000,
				ordered: false
			)
			|> Enum.map(fn {:ok, result} -> result end)

		assert Enum.all?(results, &(&1 == per_page))

		assert Database.one(from m in "market", where: m.order_id >= @base_order_id, select: count(m.order_id)) ==
						 burst * per_page
	end

	defp page_fixture(first_order_id, count) do
		for offset <- 0..(count - 1) do
			%{
				"order_id" => first_order_id + offset,
				"duration" => 90,
				"is_buy_order" => rem(offset, 2) == 0,
				"issued" => "2026-10-20T00:00:00Z",
				"location_id" => 60_003_760,
				"min_volume" => 1,
				"price" => 100.0 + offset,
				"range" => "station",
				"system_id" => 30_000_142,
				"type_id" => 34,
				"volume_remain" => 10,
				"volume_total" => 10
			}
		end
	end
end
