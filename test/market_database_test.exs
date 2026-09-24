defmodule Market.DatabaseTest do
	use ExUnit.Case, async: false

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

	test "returns nil for a known type with no market order" do
		Database.insert_all("names", [%{id: 2_001, name: "Empty Item"}])

		assert MarketDatabase.get_market_item("Empty Item") == nil
		assert MarketDatabase.get_market_item("") == nil
		assert MarketDatabase.get_market_item(nil) == nil
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
