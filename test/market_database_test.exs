defmodule Market.DatabaseTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Database
	alias Market.Database, as: MarketDatabase
	alias Market.Read, as: MarketRead

	setup_all do
		path =
			Path.join(
				System.tmp_dir!(),
				"marketmailer-market-database-#{System.unique_integer([:positive])}.db"
			)

		read_path =
			Path.join(
				System.tmp_dir!(),
				"marketmailer-market-read-#{System.unique_integer([:positive])}.db"
			)

		Application.put_env(:marketmailer, Database,
			database: path,
			priv: "priv/repo",
			journal_mode: :wal,
			busy_timeout: 5_000,
			pool_size: 1,
			log: false
		)

		Application.put_env(:marketmailer, ReadDatabase,
			database: read_path,
			priv: "priv/repo",
			journal_mode: :wal,
			busy_timeout: 5_000,
			pool_size: 1,
			log: false
		)

		repo_pid =
			case Process.whereis(Database) do
				nil ->
					{:ok, pid} = Database.start_link()
					Process.unlink(pid)
					pid

				pid ->
					pid
			end

		read_pid =
			case Process.whereis(ReadDatabase) do
				nil ->
					{:ok, pid} = ReadDatabase.start_link()
					Process.unlink(pid)
					pid

				pid ->
					pid
			end

		Ecto.Migrator.run(
			Database,
			Path.join(:code.priv_dir(:marketmailer), "repo/migrations"),
			:up,
			all: true
		)

		:ok = Market.Sync.ensure_read_schema()

		on_exit(fn ->
			if Process.alive?(repo_pid), do: GenServer.stop(repo_pid)
			if Process.alive?(read_pid), do: GenServer.stop(read_pid)
			File.rm_rf!(path)
			File.rm_rf!(read_path)
		end)

		:ok
	end

	setup do
		Database.delete_all("market")
		Database.delete_all("names")
		Database.delete_all("systems")
		Database.delete_all("discord")
		ReadDatabase.delete_all("market")
		ReadDatabase.delete_all("names")
		ReadDatabase.delete_all("systems")
		ReadDatabase.query!("DELETE FROM _sync_watermark", [])
		:ok
	end

	test "finds the cheapest cached sell order by case-insensitive item name" do
		insert_fixture()
		assert :ok = Market.Sync.run()

		item = MarketRead.get_market_item("  tRiTaNiUm  ")

		assert %MarketView{} = item
		assert item.type_id == 1_001
		assert item.item_name == "Tritanium"
		assert item.location_name == "Jita IV - Moon 4"
		assert item.price == 10.0
		assert item.buy_price == 110.0
		assert item.instant_sell_profit == 1_000.0
	end

	test "returns nil when the name is not present in the market" do
		insert_fixture()
		assert :ok = Market.Sync.run()

		assert MarketRead.get_market_item("Rifter") == nil
	end

	test "finds PLEX by case-insensitive name from cached rows" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [
			%{id: 44_992, name: "PLEX"},
			%{id: 60_003_760, name: "Jita IV - Moon 4"}
		])

		Database.insert_all("systems", [
			%{system_id: 30_000_142, name: "Jita", security_status: 0.9, region_name: "The Forge"},
			%{
				system_id: 30_000_143,
				name: "Rens",
				security_status: 0.7,
				region_name: "Heimatar"
			}
		])

		Database.insert_all("market", [
			%{
				order_id: 201,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_143,
				type_id: 44_992,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			},
			%{
				order_id: 202,
				duration: 1,
				is_buy_order: 1,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 110.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 44_992,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert :ok = Market.Sync.run()

		for query <- ["plex", "PLEX", "  Plex  ", "pLeX"] do
			item = MarketRead.get_market_item(query)

			assert %MarketView{} = item
			assert item.type_id == 44_992
			assert item.item_name == "PLEX"
			assert item.price == 10.0
			assert item.buy_price == 110.0
			assert item.instant_sell_profit == 1_000.0
		end
	end

	test "finds Squall by case-insensitive name from cached rows" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [
			%{id: 81_008, name: "Squall"},
			%{id: 60_003_760, name: "Jita IV - Moon 4"}
		])

		Database.insert_all("systems", [
			%{system_id: 30_000_142, name: "Jita", security_status: 0.9, region_name: "The Forge"},
			%{
				system_id: 30_000_143,
				name: "Rens",
				security_status: 0.7,
				region_name: "Heimatar"
			}
		])

		Database.insert_all("market", [
			%{
				order_id: 301,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_143,
				type_id: 81_008,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			},
			%{
				order_id: 302,
				duration: 1,
				is_buy_order: 1,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 110.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 81_008,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert :ok = Market.Sync.run()

		for query <- ["squall", "SQUALL", "  Squall  "] do
			item = MarketRead.get_market_item(query)

			assert %MarketView{} = item
			assert item.type_id == 81_008
			assert item.item_name == "Squall"
			assert item.price == 10.0
			assert item.buy_price == 110.0
			assert item.instant_sell_profit == 1_000.0
		end
	end

	test "returns nil for a known type with no market order" do
		Database.insert_all("names", [%{id: 2_001, name: "Empty Item"}])
		assert :ok = Market.Sync.run()

		assert MarketRead.get_market_item("Empty Item") == nil
		assert MarketRead.get_market_item("") == nil
		assert MarketRead.get_market_item(nil) == nil
	end

	test "suggests only items with a cached Jita 4-4 sell order" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [
			%{id: 81_008, name: "Squall"},
			%{id: 1_001, name: "Tritanium"},
			%{id: 9_999, name: "Squalene"}
		])

		Database.insert_all("market", [
			%{
				order_id: 401,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 81_008,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			},
			%{
				order_id: 402,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 12.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			},
			%{
				order_id: 403,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 123_456,
				min_volume: 1,
				price: 5.0,
				range: "station",
				system_id: 30_000_143,
				type_id: 9_999,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert :ok = Market.Sync.run()

		assert [%{item_name: "Squall"}] = MarketRead.suggest_items("squ")
		assert [%{item_name: "Squall"}] = MarketRead.suggest_items("  SQUA  ")
		assert MarketRead.suggest_items("") == []
		assert MarketRead.suggest_items(nil) == []
	end

	test "type-name seeding is a no-op offline when nothing is missing" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [%{id: 1_001, name: "Tritanium"}])

		Database.insert_all("market", [
			%{
				order_id: 501,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert Universe.Database.seed_missing_type_names(500) == :ok
	end

	test "location and system seeding are no-ops offline when nothing is missing" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [
			%{id: 1_001, name: "Tritanium"},
			%{id: 60_003_760, name: "Jita IV - Moon 4"}
		])

		Database.insert_all("systems", [
			%{system_id: 30_000_142, name: "Jita", security_status: 0.9, region_name: "The Forge"}
		])

		Database.insert_all("market", [
			%{
				order_id: 502,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert Universe.Database.seed_missing_location_names(500) == :ok
		assert Universe.Database.seed_missing_systems(20) == :ok
	end

	test "missing cache counts track each backlog independently" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [%{id: 1_001, name: "Tritanium"}])

		Database.insert_all("market", [
			%{
				order_id: 503,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_143,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		# Type names are warm but the location and system backlogs are not:
		# each counter must report its own cache so a drained cache never
		# gates the others.
		assert Universe.Database.missing_type_name_count() == 0
		assert Universe.Database.missing_location_name_count() == 1
		assert Universe.Database.missing_system_count() == 1
	end

	test "sync copies write rows to the read database idempotently" do
		insert_fixture()
		assert :ok = Market.Sync.run()
		assert :ok = Market.Sync.run()

		assert Database.aggregate("market", :count) == ReadDatabase.aggregate("market", :count)
		assert ReadDatabase.aggregate("market", :count) == 3

		items = MarketRead.get_items_less_than_jita_buy()
		assert length(items) == 2
		assert Enum.at(items, 0).system_name == "Rens"
		assert Enum.at(items, 0).security_status == 0.7
	end

	test "sync propagates same-second price updates to the read database" do
		insert_fixture()
		assert :ok = Market.Sync.run()

		# Same-second re-upsert (identical updated_at): the boundary re-copy
		# must still carry the new price across.
		MarketDatabase.upsert_orders([order_fixture(101, 99.5)])
		assert :ok = Market.Sync.run()

		assert %{price: 99.5} = ReadDatabase.one(from m in "market", where: m.order_id == 101, select: %{price: m.price})
	end

	test "reads ordered undercutting rows from the market list view" do
		insert_fixture()
		assert :ok = Market.Sync.run()

		items = MarketRead.get_items_less_than_jita_buy()

		assert length(items) == 2
		assert Enum.at(items, 0).item == "Tritanium"
		assert Enum.at(items, 0).sell_price == 10.0
		assert Enum.at(items, 0).buy_price == 110.0
		assert Enum.at(items, 0).margin == 100.0
		assert Enum.at(items, 0).type_id == 1_001
	end

	test "the market list view is created by the migration" do
		assert %{rows: [["marketListView"]]} =
						 Database.query!("SELECT name FROM sqlite_master WHERE type = 'view' AND name = 'marketListView'")
	end

	test "upsert_orders persists multi-chunk pages and replaces on conflict" do
		size = MarketDatabase.upsert_chunk_size()
		assert size > 0

		orders = for n <- 1..(size * 2 + 50), do: order_fixture(50_000 + n)

		assert MarketDatabase.upsert_orders(orders) == size * 2 + 50
		assert Database.aggregate("market", :count) == size * 2 + 50

		# Same ids, new prices: conflict path replaces instead of duplicating.
		orders = for n <- 1..(size * 2 + 50), do: order_fixture(50_000 + n, 99.5)
		assert MarketDatabase.upsert_orders(orders) == size * 2 + 50
		assert Database.aggregate("market", :count) == size * 2 + 50

		assert [%{price: 99.5}] =
						 Database.all(from m in "market", where: m.order_id == 50_001, select: %{price: m.price})
	end

	test "concurrent upserts through the single writer never fail" do
		tasks =
			for w <- 1..20 do
				Task.async(fn ->
					orders = for n <- 1..30, do: order_fixture(60_000 + w * 100 + n)
					MarketDatabase.upsert_orders(orders)
				end)
			end

		assert Enum.sum(Task.await_many(tasks, 30_000)) == 600
		assert Database.aggregate("market", :count) == 600
	end

	test "lists registered Discord channels in guild order" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("discord", [
			%{guild_id: 20, channel_id: 200, inserted_at: now, updated_at: now},
			%{guild_id: 10, channel_id: 100, inserted_at: now, updated_at: now}
		])

		assert Discord.Database.registered_channels() == [100, 200]
	end

	defp insert_fixture do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [
			%{id: 1_001, name: "Tritanium"},
			%{id: 1_002, name: "Tritanium Blueprint"},
			%{id: 60_003_760, name: "Jita IV - Moon 4"}
		])

		Database.insert_all("systems", [
			%{system_id: 30_000_142, name: "Jita", security_status: 0.0, region_name: "The Forge"},
			%{
				system_id: 30_000_143,
				name: "Rens",
				security_status: 0.7,
				region_name: "Home Systems"
			}
		])

		Database.insert_all("market", [
			market_row(101, 30_000_143, 1_001, 10.0, 0, now),
			market_row(102, 30_000_143, 1_001, 12.0, 0, now),
			market_row(103, 30_000_142, 1_001, 110.0, 1, now)
		])
	end

	defp order_fixture(order_id, price \\ 10.0) do
		%{
			"order_id" => order_id,
			"duration" => 1,
			"is_buy_order" => false,
			"issued" => "2026-09-24T00:00:00Z",
			"location_id" => 60_003_760,
			"min_volume" => 1,
			"price" => price,
			"range" => "station",
			"system_id" => 30_000_142,
			"type_id" => 1_001,
			"volume_remain" => 10,
			"volume_total" => 10
		}
	end

	defp market_row(order_id, system_id, type_id, price, is_buy_order, now) do
		%{
			order_id: order_id,
			duration: 1,
			is_buy_order: is_buy_order,
			issued: "2026-09-24T00:00:00Z",
			location_id: 60_003_760,
			min_volume: 1,
			price: price,
			range: "station",
			system_id: system_id,
			type_id: type_id,
			volume_remain: 10,
			volume_total: 10,
			inserted_at: now,
			updated_at: now
		}
	end
end
