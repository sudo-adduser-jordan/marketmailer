defmodule Etag.ExpiryTest do
	# Crash-resume TTL persistence: expiry survives in SQLite, unexpected
	# entries (missing/NULL/expired/absurd) fetch now instead of skipping.
	use ExUnit.Case, async: false

	setup_all do
		# Use the app-booted test repo (pollers disabled, isolated priv/data/test.db):
		# reconfiguring Database here would poison the shared repo for the
		# rest of the suite. Migration is idempotent. Market.DatabaseTest
		# stops/restarts the shared repo in its lifecycle, so wait for it.
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

	# The shared test repo is stopped/restarted by other modules' lifecycles;
	# poll until a trivial query succeeds (or the deadline passes, then fail).
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
		Etag.Database.upsert_etag(url, "legacy", nil)
		assert Etag.Database.resume_delay_ms(url) == 0
	end

	test "pages_for_region parses known pages and ignores garbage urls" do
		region = 98_000_005
		Etag.Database.upsert_etag(ESI.page_url(region, 1), "e1", System.system_time(:millisecond) + 60_000)
		Etag.Database.upsert_etag(ESI.page_url(region, 2), "e2", System.system_time(:millisecond) + 60_000)
		Etag.Database.upsert_etag("https://esi.evetech.net/v1/markets/#{region}/orders/?nonsense", "junk", 1)

		assert Enum.sort(Etag.Database.pages_for_region(region)) == [1, 2]
	end

	test "ESI meta carries absolute expires_at consistent with ttl" do
		future =
			DateTime.utc_now()
			|> DateTime.add(300, :second)
			|> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

		http_fun = fn _url, _opts ->
			{:ok,
			 %{
				 status: 304,
				 headers: %{"expires" => [future], "x-pages" => ["2"], "etag" => ["\"abc\""]},
				 body: ""
			 }}
		end

		before = System.system_time(:millisecond)
		{:not_modified, ctx} = ESI.fetch(98_000_006, 1, http_fun: http_fun)
		assert ctx.expires_at - before >= ctx.ttl - 1_000
		assert ctx.expires_at - before <= ctx.ttl + 5_000
	end
end
