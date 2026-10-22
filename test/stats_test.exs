defmodule Marketmailer.StatsTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	@probe_type_id 7_000_001

	setup do
		Marketmailer.Stats.clear_cache()
		on_exit(fn -> Marketmailer.Stats.clear_cache() end)
		:ok
	end

	test "serves the aggregate from the cache until it is cleared" do
		assert {:ok, first} = Marketmailer.Stats.stats()
		assert is_integer(first.query_ms) and first.query_ms >= 0
		assert is_integer(first.page_count) and first.page_count > 0

		# A row added inside the TTL must not appear: the second call is served
		# from the cache, so the database is not queried again.
		Database.insert_all("names", [%{id: @probe_type_id, name: "Stats Probe"}])
		on_exit(fn -> Database.delete_all(from n in "names", where: n.id == ^@probe_type_id) end)

		assert {:ok, second} = Marketmailer.Stats.stats()
		assert second == first

		Marketmailer.Stats.clear_cache()

		assert {:ok, third} = Marketmailer.Stats.stats()
		assert third.known_names == first.known_names + 1
	end

	test "runtime stats describe the cache and the poller without any supervision" do
		runtime = Marketmailer.Stats.runtime()

		assert runtime.regions == length(Marketmailer.RegionManagerSupervisor.region_ids())
		assert is_integer(runtime.page_workers) and runtime.page_workers >= 0
		assert is_integer(runtime.uptime_seconds) and runtime.uptime_seconds >= 0
		assert is_integer(runtime.cache_entries) and runtime.cache_entries >= 0
		assert is_integer(runtime.esi_error_entries)
		assert is_integer(runtime.esi_rate_entries)
		assert is_integer(runtime.janice_cache_entries)
		assert is_nil(runtime.sde_build) or is_binary(runtime.sde_build)
		assert is_integer(runtime.contract_page_workers) and runtime.contract_page_workers >= 0
		assert is_nil(runtime.contract_active_round) or is_integer(runtime.contract_active_round)
		assert is_nil(runtime.contract_top_round) or is_integer(runtime.contract_top_round)
		assert is_nil(runtime.contract_last_desired) or is_integer(runtime.contract_last_desired)
	end

	test "a missing ETS table degrades to zero instead of raising" do
		assert Marketmailer.Stats.ets_size(:marketmailer_stats_missing_table) == 0
	end
end
