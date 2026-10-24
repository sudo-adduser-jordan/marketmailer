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

		if :ets.whereis(:network_state) == :undefined do
			:ets.new(:network_state, [:named_table, :set, :public, read_concurrency: true])
		end

		:ets.match_delete(:esi_rate_state, {{:rate_block, :_}, :_})
		:ets.match_delete(:esi_rate_state, {{:rate_group, :_}, :_})
		:ets.delete(:esi_error_state, :blocked_until)
		:ets.delete(:esi_error_state, :maintenance_mode)
		MarketmailerTest.Fixtures.reset_network()

		ExUnit.Callbacks.on_exit(fn ->
			:ets.delete(:esi_error_state, :maintenance_mode)
			:ets.delete(:esi_error_state, :blocked_until)
			:ets.match_delete(:esi_rate_state, {{:rate_block, :_}, :_})
			:ets.match_delete(:esi_rate_state, {{:rate_group, :_}, :_})
			MarketmailerTest.Fixtures.reset_network()
		end)

		:ok
	end

	test "handles rate limit" do
		url = "https://esi.evetech.net/v1/markets/990001/orders/?page=1"

		http = fn _url, _opts ->
			{:ok,
			 response(429, %{
				 "x-ratelimit-group" => ["market"],
				 "x-ratelimit-limit" => ["100/1m"],
				 "x-ratelimit-remaining" => ["0"],
				 "retry-after" => ["2"]
			 })}
		end

		assert {:error, :rate_limited, meta} = ESI.get(url, http_fun: http, conditional: false)
		assert meta.group == "market"
		assert meta.retry_after_ms == 2_000

		assert [{{:rate_block, "market"}, %{retry_after_ms: 2_000, until: until}}] =
						 :ets.lookup(:esi_rate_state, {:rate_block, "market"})

		assert until > System.system_time(:millisecond)
	end

	test "handles errors" do
		url = "https://esi.evetech.net/v1/markets/990002/orders/?page=1"

		http = fn _url, _opts -> {:error, :econnrefused} end

		assert {:error, :econnrefused} = ESI.get(url, http_fun: http, conditional: false)
		assert eventually(fn -> Marketmailer.Maintenance.down?() end)
		assert Marketmailer.Maintenance.status().reason =~ "econnrefused"
	end

	test "handles status codes" do
		url = "https://esi.evetech.net/v1/markets/990003/orders/?page=1"

		ok = fn _url, _opts ->
			{:ok, response(200, %{"etag" => ["\"a\""], "x-pages" => ["3"]}, "[{\"order_id\":1}]")}
		end

		assert {:ok, body, meta} = ESI.get(url, http_fun: ok, conditional: false)
		assert body == "[{\"order_id\":1}]"
		assert meta.pages == 3
		assert meta.etag == "\"a\""
		assert meta.ttl == 60_000

		not_modified = fn _url, _opts -> {:ok, response(304, %{})} end
		assert {:not_modified, _meta} = ESI.get(url, http_fun: not_modified, conditional: false)

		not_found = fn _url, _opts -> {:ok, response(404, %{})} end
		assert {:error, :not_found, _meta} = ESI.get(url, http_fun: not_found, conditional: false)

		unavailable = fn _url, _opts -> {:ok, response(503, %{})} end

		assert {:error, :service_unavailable, _meta} =
						 ESI.get(url, http_fun: unavailable, conditional: false)

		assert ESI.maintenance_active?()
	end

	test "handles etags" do
		url = "https://esi.evetech.net/v1/markets/990004/orders/?page=1"
		on_exit(fn -> :ets.delete(:market_cache, url) end)

		:ets.insert(:market_cache, {url, "\"cached\"", System.system_time(:millisecond) + 60_000})

		parent = self()

		http = fn _url, opts ->
			send(parent, {:headers, opts[:headers]})
			{:ok, response(304, %{})}
		end

		assert {:not_modified, meta} = ESI.get(url, http_fun: http)
		assert meta.url == url

		assert_receive {:headers, headers}
		assert {"User-Agent", "lostcoastwizard > BEAM me up, Scotty!"} in headers
		assert {"If-None-Match", "\"cached\""} in headers

		fresh = fn _url, _opts -> {:ok, response(200, %{"etag" => ["\"new\""]}, "[]")} end
		assert {:ok, "[]", meta} = ESI.get(url, http_fun: fresh)
		assert meta.etag == "\"new\""
	end

	test "handles timeouts" do
		url = "https://esi.evetech.net/v1/markets/990005/orders/?page=1"

		http = fn _url, _opts -> {:error, :timeout} end

		assert {:error, :timeout} = ESI.get(url, http_fun: http, conditional: false)
		assert Marketmailer.Maintenance.down?()
	end

	test "handles transport errors" do
		url = "https://esi.evetech.net/v1/markets/990006/orders/?page=1"
		error = %Mint.TransportError{reason: :econnrefused}

		assert ESI.network_error?(error)
		refute ESI.network_error?(:bad_request)

		http = fn _url, _opts -> {:error, error} end

		assert {:error, ^error} = ESI.get(url, http_fun: http, conditional: false)
		assert Marketmailer.Maintenance.down?()
	end

	test "error limit does not fall below limit-1" do
		url = "https://esi.evetech.net/v1/markets/990007/orders/?page=1"

		low = fn _url, _opts ->
			{:ok, response(200, %{"x-esi-error-limit-remain" => ["5"]})}
		end

		now = System.system_time(:millisecond)
		assert {:ok, _body, meta} = ESI.get(url, http_fun: low, conditional: false)
		assert meta.ttl >= 61_000

		assert [{:blocked_until, until}] = :ets.lookup(:esi_error_state, :blocked_until)
		assert until >= now + 61_000

		:ets.delete(:esi_error_state, :blocked_until)

		healthy = fn _url, _opts ->
			{:ok, response(200, %{"x-esi-error-limit-remain" => ["100"]})}
		end

		assert {:ok, _body, meta} = ESI.get(url, http_fun: healthy, conditional: false)
		assert meta.ttl == 60_000
		assert :ets.lookup(:esi_error_state, :blocked_until) == []
	end

	defp response(status, headers, body \\ "") do
		%Req.Response{status: status, headers: headers, body: body}
	end

	defp eventually(fun, attempts \\ 50) do
		cond do
			fun.() ->
				true

			attempts <= 0 ->
				false

			true ->
				Process.sleep(10)
				eventually(fun, attempts - 1)
		end
	end
end
