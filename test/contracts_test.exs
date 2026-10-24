defmodule ContractsTest do
	use ExUnit.Case, async: false

	@round 42
	@now Contracts.now_ms()
	@future @now + 3_600_000

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
	end

	test "contracts exits" do
	end

	test "contracts items exits" do
	end

	test "contracts types excluded" do
	end

	test "captials are included in contracts" do
	end

	test "captials are valued at market average" do
	end

	test "contracts are filtered by margin" do
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
