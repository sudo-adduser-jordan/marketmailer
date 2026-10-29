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
		:ets.match_delete(:esi_error_state, {{:pause_note, :_}, :_})
		:ets.delete(:esi_error_state, :pause_noted)
		:ets.delete(:esi_error_state, :blocked_until)
		MarketmailerTest.Fixtures.reset_esi_maintenance()
		MarketmailerTest.Fixtures.reset_network()

		ExUnit.Callbacks.on_exit(fn ->
			MarketmailerTest.Fixtures.reset_esi_maintenance()
			:ets.delete(:esi_error_state, :blocked_until)
			:ets.delete(:esi_error_state, :pause_noted)
			:ets.match_delete(:esi_error_state, {{:pause_note, :_}, :_})
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
		assert eventually(fn -> Marketmailer.Maintenance.down?() end)
	end

	test "a closed keepalive socket does not pause polling" do
		url = "https://esi.evetech.net/v1/markets/990015/orders/?page=1"
		error = %Mint.TransportError{reason: :closed}

		:persistent_term.put({:marketmailer_test, :probe_result}, :ok)
		on_exit(fn -> :persistent_term.erase({:marketmailer_test, :probe_result}) end)

		http = fn _url, _opts -> {:error, error} end

		assert {:error, ^error} = ESI.get(url, http_fun: http, conditional: false)
		refute Marketmailer.Maintenance.down?()
	end

	test "handles transport errors" do
		url = "https://esi.evetech.net/v1/markets/990006/orders/?page=1"
		error = %Mint.TransportError{reason: :econnrefused}
		closed = %Mint.TransportError{reason: :closed}

		assert ESI.network_error?(error)
		refute ESI.network_error?(:bad_request)
		assert ESI.hard_disconnect?(error)
		refute ESI.transient_error?(error)
		assert ESI.transient_error?(closed)
		refute ESI.hard_disconnect?(closed)

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

	test "a single error does not park the poller while the budget is healthy" do
		url = "https://esi.evetech.net/v1/markets/990008/orders/?page=1"

		mostly_healthy = fn _url, _opts ->
			{:ok, response(200, %{"x-esi-error-limit-remain" => ["50"]})}
		end

		assert {:ok, _body, meta} = ESI.get(url, http_fun: mostly_healthy, conditional: false)
		assert meta.ttl == 60_000
		assert :ets.lookup(:esi_error_state, :blocked_until) == []

		low = fn _url, _opts ->
			{:ok, response(200, %{"x-esi-error-limit-remain" => ["19"]})}
		end

		assert {:ok, _body, _meta} = ESI.get(url, http_fun: low, conditional: false)
		assert [{:blocked_until, until}] = :ets.lookup(:esi_error_state, :blocked_until)
		assert until > System.system_time(:millisecond)
	end

	test "the pause follows the error-limit reset window" do
		url = "https://esi.evetech.net/v1/contracts/public/items/990009/"

		not_found = fn _url, _opts ->
			{:ok,
			 response(404, %{
				 "x-esi-error-limit-remain" => ["10"],
				 "x-esi-error-limit-reset" => ["4"]
			 })}
		end

		now = System.system_time(:millisecond)
		assert {:error, :not_found, _meta} = ESI.get(url, http_fun: not_found, conditional: false)

		assert [{:blocked_until, until}] = :ets.lookup(:esi_error_state, :blocked_until)
		assert until >= now + 5_000
		assert until <= now + 6_000
	end

	test "every waiter on one window logs a single pause record" do
		until = System.system_time(:millisecond) + 300
		:ets.insert(:esi_error_state, {:blocked_until, until})

		log =
			ExUnit.CaptureLog.capture_log(fn ->
				1..5
				|> Enum.map(fn _ -> Task.async(fn -> ESI.wait_for_error_window() end) end)
				|> Enum.each(&Task.await/1)
			end)

		assert log |> String.split("esi_error_limit_pause") |> length() == 2
	end

	test "a raised request pauses the fleet instead of killing the caller" do
		url = "https://esi.evetech.net/v1/markets/990010/orders/?page=1"
		:persistent_term.put({:marketmailer_test, :probe_result}, :ok)
		on_exit(fn -> :persistent_term.erase({:marketmailer_test, :probe_result}) end)

		http = fn _url, _opts ->
			raise "Finch was unable to provide a connection within the timeout due to excess queuing for connections"
		end

		log =
			ExUnit.CaptureLog.capture_log(fn ->
				assert {:error, %{reason: :request_failed}} = ESI.get(url, http_fun: http, conditional: false)
			end)

		assert log =~ "esi_http_error"
		refute ESI.maintenance_active?()
		refute Marketmailer.Maintenance.down?()
	end

	test "invalid request options are reported as such instead of swallowed" do
		url = "https://esi.evetech.net/v1/markets/990013/orders/?page=1"

		http = fn _url, _opts ->
			raise ArgumentError, "cannot set both :finch and :connect_options"
		end

		log =
			ExUnit.CaptureLog.capture_log(fn ->
				assert {:error, %{reason: :invalid_request}} = ESI.get(url, http_fun: http, conditional: false)
			end)

		assert log =~ "esi_request_invalid"
		refute ESI.maintenance_active?()
		refute ESI.Maintenance.window_open?()
	end

	test "request options use the shared pool with an unbounded checkout" do
		opts = ESI.request_options([])
		timeout = Marketmailer.Maintenance.request_timeout_ms()

		assert opts[:finch] == [name: ESI.Finch, pool_timeout: :infinity]
		refute Keyword.has_key?(opts, :connect_options)
		assert opts[:receive_timeout] == timeout
		assert opts[:retry] == false
	end

	test "market fetches keep one request per worker and honor an explicit checkout" do
		url = "https://esi.evetech.net/v1/markets/990014/orders/?page=1"
		parent = self()

		http = fn _url, opts ->
			send(parent, {:request_options, opts})
			{:ok, response(304, %{"expires" => ["Thu, 29 Oct 2026 03:59:52 GMT"]})}
		end

		assert {:not_modified, _meta} = ESI.fetch(990_014, 1, http_fun: http, conditional: false)
		assert_received {:request_options, opts}
		assert opts[:retry] == false
		assert opts[:finch] == [name: ESI.Finch, pool_timeout: :infinity]

		assert {:not_modified, _meta} = ESI.get(url, http_fun: http, conditional: false, pool_timeout: 5_000)
		assert_received {:request_options, opts}
		assert opts[:finch] == [name: ESI.Finch, pool_timeout: 5_000]
	end

	test "an unanswered request never opens a maintenance window" do
		url = "https://esi.evetech.net/v1/markets/990012/orders/?page=1"

		http = fn _url, _opts ->
			{:error, %{reason: :request_failed, detail: "pool timeout"}}
		end

		assert {:error, %{reason: :request_failed}} =
						 ESI.get(url, http_fun: http, conditional: false)

		refute ESI.maintenance_active?()
		refute ESI.Maintenance.window_open?()
	end

	test "a success closes the maintenance window" do
		url = "https://esi.evetech.net/v1/markets/990011/orders/?page=1"

		ESI.Maintenance.down(%{status: 503, url: url})
		assert ESI.maintenance_active?()

		ok = fn _url, _opts -> {:ok, response(200, %{})} end
		assert {:ok, _body, _meta} = ESI.get(url, http_fun: ok, conditional: false)
		refute ESI.maintenance_active?()
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
