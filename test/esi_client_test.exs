defmodule ESI.ClientTest do
		# The default Req path must keep retry internals off the warning sink:
		# attempt warnings carry no region/page context (final failures are
		# logged by us as esi_http_error/page_fetch_error instead).
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
end
