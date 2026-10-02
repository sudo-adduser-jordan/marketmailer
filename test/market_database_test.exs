defmodule Market.DatabaseTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Database
	alias Market.Database, as: MarketDatabase

	setup_all do
		path =
			Path.join(
				System.tmp_dir!(),
				"marketmailer-market-database-#{System.unique_integer([:positive])}.db"
			)

		Application.put_env(:marketmailer, Database,
			database: path,
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

		Ecto.Migrator.run(
			Database,
			Path.join(:code.priv_dir(:marketmailer), "repo/migrations"),
			:up,
			all: true
		)

		on_exit(fn ->
			if Process.alive?(repo_pid), do: GenServer.stop(repo_pid)
			File.rm_rf!(path)
		end)

		:ok
	end

	setup do
		Database.delete_all("market")
		Database.delete_all("names")
		Database.delete_all("systems")
		Database.delete_all("discord")
		:ok
	end

	test "finds the cheapest cached sell order by case-insensitive item name" do
		insert_fixture()

		item = MarketDatabase.get_market_item("  tRiTaNiUm  ")

		assert %MarketView{} = item
		assert item.type_id == 1_001
		assert item.item_name == "Tritanium"
		assert item.location_name == "Jita IV - Moon 4"
		assert item.price == 10.0
		assert item.instant_sell_profit == 1_000.0
	end

	test "returns nil when the name is not present in the market" do
		insert_fixture()

		assert MarketDatabase.get_market_item("Rifter") == nil
	end

	test "finds PLEX by case-insensitive name from cached rows" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [
			%{id: 44_992, name: "PLEX"},
			%{id: 2_001, name: "Jita IV - Moon 4"}
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
				location_id: 2_001,
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
				location_id: 2_001,
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

		for query <- ["plex", "PLEX", "  Plex  ", "pLeX"] do
			item = MarketDatabase.get_market_item(query)

			assert %MarketView{} = item
			assert item.type_id == 44_992
			assert item.item_name == "PLEX"
			assert item.price == 10.0
			assert item.instant_sell_profit == 1_000.0
		end
	end

	test "returns nil for a known type with no market order" do
		Database.insert_all("names", [%{id: 2_001, name: "Empty Item"}])

		assert MarketDatabase.get_market_item("Empty Item") == nil
		assert MarketDatabase.get_market_item("") == nil
		assert MarketDatabase.get_market_item(nil) == nil
	end

	test "reads ordered undercutting rows from the market list view" do
		insert_fixture()

		items = MarketDatabase.get_items_less_than_jita_buy()

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
			%{id: 2_001, name: "Jita IV - Moon 4"}
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
			"location_id" => 2_001,
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
			location_id: 2_001,
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
