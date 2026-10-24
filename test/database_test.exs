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
	end

	test "database tables exist" do
	end

	test "etag expires" do
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
	end

	test "database tables exist" do
	end

	test "case-insensitive match" do
	end

	test "PLEX exists" do
	end

	test "npc owned structures exist" do
	end

	test "player owned structures do not exists" do
	end

	test "Jita buy-wall does not contain captials" do
	end

	test "stat command is valid" do
	end

	test "orders are updated in batches" do
	end

	test "orders that do not exist are removed" do
	end

	test "orders have an etag" do
	end

	test "all orders successfuly write to database" do
	end
end

defmodule Database.WriterTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Market.Database, as: MarketDatabase

	setup do
		on_exit(fn -> Database.delete_all(from(m in "market", where: m.order_id >= @base_order_id)) end)
		:ok
	end

	test "a burst of page writes all succeeds with no timeouts" do
	end

	defp page_fixture(first_order_id, count) do
	end
end
