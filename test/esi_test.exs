defmodule ESI.ClientTest do
		use ExUnit.Case, async: false

		setup do
				if :ets.whereis(:market_cache) == :undefined do
						:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
				end

				if :ets.whereis(:esi_error_state) == :undefined do
						:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])
				end

				if :ets.whereis(:esi_rate_state) == :undefined do
						:ets.new(:esi_rate_state, [:named_table, :set, :public, read_concurrency: true])
				end

				:ets.match_delete(:esi_rate_state, {{:rate_block, :_}, :_})
				:ets.match_delete(:esi_rate_state, {{:rate_group, :_}, :_})

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

		test "404 maps to :not_found with meta" do
				http_fun = fn _url, _opts ->
						{:ok,
							%{
									status: 404,
									headers: %{"x-pages" => ["5"]},
									body: ""
							}}
				end

				assert {:error, :not_found, ctx} = ESI.fetch(98_001_002, 9, http_fun: http_fun)
				assert ctx.pages == 5
		end

		test "other 4xx stay as integer errors" do
				http_fun = fn _url, _opts ->
						{:ok, %{status: 400, headers: %{}, body: ""}}
				end

				assert {:error, 400} = ESI.fetch(98_001_003, 1, http_fun: http_fun)
		end

		test "429 maps to :rate_limited and surfaces Retry-After" do
				http_fun = fn _url, _opts ->
						{:ok, %{status: 429, headers: %{"retry-after" => ["30"], "x-pages" => ["1"]}, body: ""}}
				end

				assert {:error, :rate_limited, ctx} = ESI.fetch(98_001_004, 1, http_fun: http_fun)
				assert ctx.retry_after_ms == 30_000
		end

		test "a low ESI error limit trips the global pause" do
				:ets.delete(:esi_error_state, :blocked_until)

				http_fun = fn _url, _opts ->
						{:ok, %{status: 200, headers: %{"x-esi-error-limit-remain" => ["5"]}, body: "[]"}}
				end

				assert {:ok, _body, ctx} = ESI.fetch(98_001_005, 1, http_fun: http_fun)
				assert ctx.ttl >= 61_000
				assert [{:blocked_until, blocked_until}] = :ets.lookup(:esi_error_state, :blocked_until)
				assert blocked_until > System.system_time(:millisecond)
		end

		test "carries bucket headers into the response meta" do
				http_fun = fn _url, _opts ->
						{:ok,
							%{
									status: 200,
									headers: %{
											"x-ratelimit-group" => ["market-order"],
											"x-ratelimit-limit" => ["12000/15m"],
											"x-ratelimit-remaining" => ["4562"],
											"x-ratelimit-used" => ["2"]
									},
									body: "[]"
							}}
				end

				assert {:ok, _body, ctx} = ESI.fetch(98_002_001, 1, http_fun: http_fun)
				assert ctx.group == "market-order"
				assert ctx.rate_limit.max == 12_000
				assert ctx.rate_limit.window_ms == 900_000
				assert ctx.rate_limit.remaining == 4_562
				assert ctx.rate_limit.used == 2
		end

		test "a 429 pauses the whole rate-limit group" do
				previous = Application.get_env(:marketmailer, :esi_rate_limit)
				Application.put_env(:marketmailer, :esi_rate_limit, enabled: true, max_block_ms: 120, jitter_ms: 0)

				on_exit(fn ->
						if previous do
								Application.put_env(:marketmailer, :esi_rate_limit, previous)
						else
								Application.delete_env(:marketmailer, :esi_rate_limit)
						end
				end)

				limited = fn _url, _opts ->
						{:ok,
							%{
									status: 429,
									headers: %{
											"retry-after" => ["0.2"],
											"x-ratelimit-group" => ["market-order"],
											"x-ratelimit-limit" => ["12000/15m"],
											"x-ratelimit-remaining" => ["0"]
									},
									body: ""
							}}
				end

				assert {:error, :rate_limited, ctx} = ESI.fetch(98_002_002, 1, http_fun: limited)
				assert ctx.retry_after_ms == 200

				assert [{{:rate_block, "market-order"}, %{until: until}}] =
													:ets.lookup(:esi_rate_state, {:rate_block, "market-order"})

				assert until > System.system_time(:millisecond)

				ok = fn _url, _opts -> {:ok, %{status: 200, headers: %{}, body: "[]"}} end
				started = System.monotonic_time(:millisecond)
				assert {:ok, _body, _ctx} = ESI.fetch(98_002_003, 1, http_fun: ok)
				assert System.monotonic_time(:millisecond) - started >= 100
		end

		test "an ungrouped 429 leaves the bucket gate alone" do
				http_fun = fn _url, _opts ->
						{:ok, %{status: 429, headers: %{"retry-after" => ["5"]}, body: ""}}
				end

				assert {:error, :rate_limited, ctx} = ESI.fetch(98_002_004, 1, http_fun: http_fun)
				assert ctx.retry_after_ms == 5_000
				assert :ets.match(:esi_rate_state, {{:rate_block, :_}, :_}) == []
		end
end
