defmodule ESI.ClientTest do
		use ExUnit.Case, async: false

		setup do
				if :ets.whereis(:market_cache) == :undefined do
						:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
				end

				if :ets.whereis(:esi_error_state) == :undefined do
						:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])
				end

				:ok
		end

		test "default Req path quiets retry logs to info" do
				test_pid = self()

				http_fun = fn _url, opts ->
						send(test_pid, {:req_opts, opts})

						{:ok,
							%{
									status: 304,
									headers: %{"x-pages" => ["1"]},
									body: ""
							}}
				end

				assert {:not_modified, _ctx} = ESI.fetch(98_001_001, 1, http_fun: http_fun)
				assert_received {:req_opts, opts}
				assert Keyword.get(opts, :retry_log_level) == :info
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
