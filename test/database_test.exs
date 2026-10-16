defmodule Etag.ExpiryTest do
	use ExUnit.Case, async: false

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

	test "upsert round-trips etag and expires_at through SQLite and ETS" do
		url = ESI.page_url(98_000_001, 1)
		expires_at = System.system_time(:millisecond) + 300_000

		Etag.Database.upsert_etag(url, "etag-1", expires_at)

		assert Etag.Database.get_etag(url) == "etag-1"
		assert Etag.Database.get_expiry(url) == expires_at
		assert :ets.lookup(:market_cache, url) == [{url, "etag-1", expires_at}]
	end

	test "resume_delay_ms waits on unexpired entries" do
		url = ESI.page_url(98_000_002, 1)
		expires_at = System.system_time(:millisecond) + 300_000
		Etag.Database.upsert_etag(url, "etag-2", expires_at)

		delay = Etag.Database.resume_delay_ms(url)
		assert delay > 0 and delay <= 300_000
	end

	test "unexpected entries fetch now: missing, expired, absurd future" do
		assert Etag.Database.resume_delay_ms(ESI.page_url(98_000_003, 1)) == 0

		expired_url = ESI.page_url(98_000_003, 2)
		Etag.Database.upsert_etag(expired_url, "old", System.system_time(:millisecond) - 1_000)
		assert Etag.Database.resume_delay_ms(expired_url) == 0

		absurd_url = ESI.page_url(98_000_003, 3)
		Etag.Database.upsert_etag(absurd_url, "far", System.system_time(:millisecond) + 10 * 3_600_000)
		assert Etag.Database.resume_delay_ms(absurd_url) == 0
	end

	test "NULL expiry from pre-migration rows fetches now" do
		url = ESI.page_url(98_000_004, 1)
		Etag.Database.upsert_etag(url, "stale", nil)
		assert Etag.Database.resume_delay_ms(url) == 0
	end

	test "pages_for_region parses known pages and ignores garbage urls" do
		region = 98_000_005
		Etag.Database.upsert_etag(ESI.page_url(region, 1), "e1", System.system_time(:millisecond) + 60_000)
		Etag.Database.upsert_etag(ESI.page_url(region, 2), "e2", System.system_time(:millisecond) + 60_000)
		Etag.Database.upsert_etag("https://esi.evetech.net/v1/markets/#{region}/orders/?nonsense", "junk", 1)

		assert Enum.sort(Etag.Database.pages_for_region(region)) == [1, 2]
	end

	test "prune_region drops pages above max from SQLite and ETS" do
		region = 98_000_007
		now = System.system_time(:millisecond) + 60_000
		Etag.Database.upsert_etag(ESI.page_url(region, 1), "e1", now)
		Etag.Database.upsert_etag(ESI.page_url(region, 2), "e2", now)
		Etag.Database.upsert_etag(ESI.page_url(region, 3), "e3", now)

		assert :ok = Etag.Database.prune_region(region, 2)
		assert Enum.sort(Etag.Database.pages_for_region(region)) == [1, 2]
		assert :ets.lookup(:market_cache, ESI.page_url(region, 3)) == []
		assert :ets.lookup(:market_cache, ESI.page_url(region, 2)) != []
	end
end

defmodule Market.DatabaseTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Database
	alias Market.Database, as: MarketDatabase

	setup_all do
		Ecto.Migrator.run(
			Database,
			Path.join(:code.priv_dir(:marketmailer), "repo/migrations"),
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
		assert item.buy_price == 110.0
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

		for query <- ["plex", "PLEX", "  Plex  ", "pLeX"] do
			item = MarketDatabase.get_market_item(query)

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

		for query <- ["squall", "SQUALL", "  Squall  "] do
			item = MarketDatabase.get_market_item(query)

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
		assert MarketDatabase.get_market_item("Empty Item") == nil
		assert MarketDatabase.get_market_item("") == nil
		assert MarketDatabase.get_market_item(nil) == nil
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

		assert [%{item_name: "Squall"}] = MarketDatabase.suggest_items("squ")
		assert [%{item_name: "Squall"}] = MarketDatabase.suggest_items("  SQUA  ")
		assert MarketDatabase.suggest_items("") == []
		assert MarketDatabase.suggest_items(nil) == []
	end

	test "labels player-owned structures without a names row" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [%{id: 1_001, name: "Tritanium"}])

		Database.insert_all("systems", [
			%{system_id: 30_000_142, name: "Jita", security_status: 0.9, region_name: "The Forge"},
			%{system_id: 30_000_143, name: "Rens", security_status: 0.7, region_name: "Heimatar"}
		])

		Database.insert_all("market", [
			%{
				order_id: 501,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 1_021_681_819_954,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_143,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			},
			%{
				order_id: 502,
				duration: 1,
				is_buy_order: 1,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 110.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert [%{location_name: "Player Station"}] = MarketDatabase.get_items_less_than_jita_buy()
		assert [%{location_name: "Player Station"}] = MarketDatabase.get_best_order()
	end

	test "renders ? for unmatched NPC-range locations" do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all("names", [%{id: 1_001, name: "Tritanium"}])

		Database.insert_all("systems", [
			%{system_id: 30_000_142, name: "Jita", security_status: 0.9, region_name: "The Forge"},
			%{system_id: 30_000_143, name: "Rens", security_status: 0.7, region_name: "Heimatar"}
		])

		Database.insert_all("market", [
			%{
				order_id: 503,
				duration: 1,
				is_buy_order: 0,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_397,
				min_volume: 1,
				price: 10.0,
				range: "station",
				system_id: 30_000_143,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			},
			%{
				order_id: 504,
				duration: 1,
				is_buy_order: 1,
				issued: "2026-09-24T00:00:00Z",
				location_id: 60_003_760,
				min_volume: 1,
				price: 110.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 1_001,
				volume_remain: 10,
				volume_total: 10,
				inserted_at: now,
				updated_at: now
			}
		])

		assert [%{location_name: "?"}] = MarketDatabase.get_items_less_than_jita_buy()
		assert [%{location_name: "?"}] = MarketDatabase.get_best_order()
	end

	test "reads persist idempotently in the single database" do
		insert_fixture()
		assert Database.aggregate("market", :count) == 3

		items = MarketDatabase.get_items_less_than_jita_buy()
		assert length(items) == 2
		assert Enum.at(items, 0).system_name == "Rens"
		assert Enum.at(items, 0).security_status == 0.7
	end

	test "same-second price updates are visible to reads" do
		insert_fixture()
		MarketDatabase.upsert_orders([order_fixture(101, 99.5)])
		assert %{price: 99.5} = Database.one(from m in "market", where: m.order_id == 101, select: %{price: m.price})
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

		orders = for n <- 1..(size * 2 + 50), do: order_fixture(50_000 + n, 99.5)
		assert MarketDatabase.upsert_orders(orders) == size * 2 + 50
		assert Database.aggregate("market", :count) == size * 2 + 50

		assert [%{price: 99.5}] =
						 Database.all(from m in "market", where: m.order_id == 50_001, select: %{price: m.price})
	end

	test "upsert_orders with a page url skips unchanged rows and deletes missing ones" do
		url = ESI.page_url(98_001_001, 1)

		orders = for n <- 1..10, do: order_fixture(80_000 + n)
		assert MarketDatabase.upsert_orders(orders, url) == 10

		before = Database.one(from m in "market", where: m.order_id == 80_001, select: m.updated_at)
		assert MarketDatabase.upsert_orders(orders, url) == 0
		assert Database.one(from m in "market", where: m.order_id == 80_001, select: m.updated_at) == before

		shorter = for n <- 1..7, do: order_fixture(80_000 + n)
		assert MarketDatabase.upsert_orders(shorter, url) == 0
		assert Database.aggregate(from(m in "market", where: m.url == ^url), :count) == 7
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

defmodule Database.WriterTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Market.Database, as: MarketDatabase

	@base_order_id 70_000_001

	setup do
		on_exit(fn -> Database.delete_all(from(m in "market", where: m.order_id >= @base_order_id)) end)
		:ok
	end

	test "write executes the fun and returns its result" do
		test_pid = self()

		assert Database.Writer.write(fn ->
						 send(test_pid, {:ran, self()})
						 :ok
					 end) == :ok

		assert_receive {:ran, _pid}
	end

	test "a burst of page writes all succeeds with no timeouts" do
		pages = 150
		rows_per_page = 1000

		{elapsed_ms, results} =
			:timer.tc(fn ->
				1..pages
				|> Task.async_stream(
					fn page ->
						first = @base_order_id + (page - 1) * rows_per_page
						MarketDatabase.upsert_orders(page_fixture(first, rows_per_page))
					end,
					max_concurrency: pages,
					timeout: 60_000
				)
				|> Enum.to_list()
			end)
			|> then(fn {us, results} -> {div(us, 1000), results} end)

		assert length(results) == pages

		for {:ok, count} <- results do
			assert count == rows_per_page
		end

		assert elapsed_ms < 20_000
	end

	defp page_fixture(first_order_id, count) do
		for i <- 0..(count - 1) do
			%{
				"order_id" => first_order_id + i,
				"duration" => 90,
				"is_buy_order" => rem(i, 2) == 0,
				"issued" => "2026-10-15T00:00:00",
				"location_id" => 60_000_001,
				"min_volume" => 1,
				"price" => 10.5,
				"range" => "region",
				"system_id" => 30_000_001,
				"type_id" => 34,
				"volume_remain" => 100,
				"volume_total" => 1000
			}
		end
	end
end
