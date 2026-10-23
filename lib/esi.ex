defmodule ESI do
	@user_agent "lostcoastwizard > BEAM me up, Scotty!"
	@maint_key :maintenance_mode
	@maint_ping_ms 10_000
	@error_limit_threshold 100
	@pause_ms 61_000
	@table :esi_error_state
	@key :blocked_until
	@rate_table :esi_rate_state
	@rate_defaults [enabled: true, max_block_ms: 900_000, jitter_ms: 500]
	@network_reasons [
		:nxdomain,
		:econnrefused,
		:econnreset,
		:etimedout,
		:timeout,
		:closed,
		:ehostunreach,
		:enetunreach,
		:enetdown,
		:eaddrnotavail,
		:epipe
	]

	def wait_for_error_window do
		now = System.system_time(:millisecond)

		case :ets.lookup(@table, @key) do
			[{@key, t}] when t > now ->
				sleep = t - now

				Marketmailer.Log.warning(
					"esi_error_limit_pause",
					%{pause_ms: sleep},
					"ESI limit low, pausing #{div(sleep, 1000)}s"
				)

				Process.sleep(sleep)

			_ ->
				:ok
		end
	end

	def wait_for_rate_window(url) do
		config = rate_config()

		if Keyword.fetch!(config, :enabled) and rate_table?() do
			case group_for_url(url) do
				nil -> :ok
				group -> sleep_for_group(group, config)
			end
		else
			:ok
		end
	end

	def page_url(region, page \\ 1), do: "https://esi.evetech.net/v1/markets/#{region}/orders/?page=#{page}"
	def contracts_page_url(region, page \\ 1), do: "https://esi.evetech.net/v1/contracts/public/#{region}/?page=#{page}"
	def contract_items_url(contract_id), do: "https://esi.evetech.net/v1/contracts/public/items/#{contract_id}/"

	def fetch(region, page \\ 1, opts \\ []) do
		get(page_url(region, page), Keyword.put(opts, :context, %{region: region, page: page}))
	end

	def get(url, opts \\ []) do
		wait_for_rate_window(url)
		http_fun = Keyword.get(opts, :http_fun, configured_http_fun())
		conditional = Keyword.get(opts, :conditional, true)
		etag = if conditional, do: Etag.Database.get_etag(url)
		context = Keyword.get(opts, :context, %{})
		timeout = Marketmailer.Maintenance.request_timeout_ms()

		headers =
			[{"User-Agent", @user_agent}] ++
				if etag, do: [{"If-None-Match", etag}], else: []

		request_opts = [
			headers: headers,
			pool_timeout: timeout,
			receive_timeout: timeout,
			connect_options: [timeout: timeout],
			retry_log_level: :info
		]

		case http_fun.(url, request_opts) do
			{:ok, response} ->
				Marketmailer.Maintenance.report_connected()
				respond(response, url)

			{:error, error} ->
				if network_error?(error), do: Marketmailer.Maintenance.report_disconnect(error)

				Marketmailer.Log.error(
					"esi_http_error",
					Map.merge(context, %{url: url, error: inspect(error)}),
					"#{url} HTTP error: #{inspect(error)}"
				)

				{:error, error}
		end
	end

	def network_error?(%{reason: reason}) when reason in @network_reasons, do: true

	def network_error?(%{__exception__: true} = error) do
		module = error.__struct__ |> Module.split() |> List.last() |> String.downcase()

		String.contains?(module, ["transport", "mint", "finch"]) or
			error
			|> Exception.message()
			|> String.downcase()
			|> String.contains?([
				"nxdomain",
				"network",
				"connection",
				"closed",
				"timeout",
				"unreachable",
				"econnrefused",
				"ehostunreach"
			])
	end

	def network_error?(reason) when reason in @network_reasons, do: true
	def network_error?({:error, reason}), do: network_error?(reason)
	def network_error?(_reason), do: false

	defp respond(%{status: 200} = response, url) do
		clear_maintenance()
		{:ok, response.body, meta(response, url)}
	end

	defp respond(%{status: 304} = response, url) do
		clear_maintenance()
		{:not_modified, meta(response, url)}
	end

	defp respond(%{status: 429} = response, url), do: {:error, :rate_limited, meta(response, url)}

	defp respond(%{status: status} = response, url) when status in [420, 500, 502, 503, 504] do
		activate_maintenance()
		{:error, :service_unavailable, meta(response, url)}
	end

	defp respond(%{status: 404} = response, url), do: {:error, :not_found, meta(response, url)}

	defp respond(response, url) do
		_ = meta(response, url)
		{:error, response.status}
	end

	defp activate_maintenance, do: :ets.insert(@table, {@maint_key, System.system_time(:millisecond) + @maint_ping_ms})

	defp clear_maintenance, do: :ets.delete(@table, @maint_key)

	def maintenance_active? do
		case :ets.lookup(@table, @maint_key) do
			[{@maint_key, t}] -> t > System.system_time(:millisecond)
			_ -> false
		end
	end

	defp meta(response, url) do
		error_rem = first(response.headers, "x-esi-error-limit-remain")
		ttl = calc_ttl(first(response.headers, "expires"))
		ttl = if remain(error_rem) < @error_limit_threshold, do: enforce_pause(ttl), else: ttl
		now = System.system_time(:millisecond)
		retry_after = retry_after_ms(response.headers)
		rate = rate_meta(response.headers)
		note_rate(response, url, rate, retry_after)

		%{
			url: url,
			etag: first(response.headers, "etag"),
			ttl: ttl,
			expires_at: now + ttl,
			pages: parse_int(first(response.headers, "x-pages")) || 1,
			retry_after_ms: retry_after,
			group: rate.group,
			rate_limit: rate_limit(rate)
		}
	end

	defp rate_meta(headers) do
		%{
			group: first(headers, "x-ratelimit-group"),
			limit: parse_limit(first(headers, "x-ratelimit-limit")),
			remaining: parse_int(first(headers, "x-ratelimit-remaining")),
			used: parse_int(first(headers, "x-ratelimit-used"))
		}
	end

	defp rate_limit(%{limit: %{} = limit} = rate) do
		Map.merge(limit, %{remaining: rate.remaining, used: rate.used})
	end

	defp rate_limit(_rate), do: nil

	defp note_rate(response, url, rate, retry_after) do
		remember_group(url, rate.group)

		if response.status == 429 do
			block_group(rate.group || group_for_url(url), retry_after, rate)
		end

		:ok
	end

	defp remember_group(_url, nil), do: :ok

	defp remember_group(url, group) when is_binary(group) and group != "" do
		if rate_table?() do
			:ets.insert(@rate_table, {{:rate_group, route_key(url)}, group})
		end

		:ok
	end

	defp remember_group(_url, _group), do: :ok

	defp group_for_url(url) do
		if rate_table?() do
			case :ets.lookup(@rate_table, {:rate_group, route_key(url)}) do
				[{{:rate_group, _key}, group}] -> group
				_ -> nil
			end
		end
	end

	defp route_key(url) do
		case URI.parse(url) do
			%URI{path: path} when is_binary(path) -> String.replace(path, ~r/\d+/, ":id")
			_ -> url
		end
	end

	defp sleep_for_group(group, config) do
		now = System.system_time(:millisecond)

		case :ets.lookup(@rate_table, {:rate_block, group}) do
			[{{:rate_block, ^group}, %{until: until}}] when is_integer(until) and until > now ->
				jitter = :rand.uniform(max(Keyword.fetch!(config, :jitter_ms), 1))
				Process.sleep(until - now + jitter)

			_ ->
				:ok
		end
	end

	defp block_group(nil, _retry_after, _rate), do: :ok

	defp block_group(group, retry_after, rate) do
		if rate_table?() do
			config = rate_config()
			now = System.system_time(:millisecond)
			pause = retry_after |> max(1_000) |> min(Keyword.fetch!(config, :max_block_ms))
			until = now + pause

			current =
				case :ets.lookup(@rate_table, {:rate_block, group}) do
					[{{:rate_block, ^group}, %{until: current}}] when is_integer(current) -> current
					_ -> 0
				end

			if until > current do
				:ets.insert(@rate_table, {{:rate_block, group}, %{until: until, retry_after_ms: pause}})

				if until > current + 1_000 do
					Marketmailer.Log.warning(
						"esi_rate_limited",
						%{
							group: group,
							retry_after_ms: pause,
							remaining: rate.remaining,
							limit: rate.limit && rate.limit.max
						},
						"ESI bucket #{group} rate limited; pausing #{div(pause, 1000)}s"
					)
				end
			end
		end

		:ok
	end

	defp parse_limit(nil), do: nil

	defp parse_limit(value) do
		case String.split(to_string(value), "/", parts: 2) do
			[max, window] ->
				with {max, ""} <- Integer.parse(String.trim(max)),
						 {amount, unit} <- Integer.parse(String.trim(window)) do
					%{max: max, window_ms: window_ms(amount, unit)}
				else
					_ -> nil
				end

			_ ->
				nil
		end
	end

	defp window_ms(amount, "s"), do: amount * 1_000
	defp window_ms(amount, "m"), do: amount * 60_000
	defp window_ms(amount, "h"), do: amount * 3_600_000
	defp window_ms(_amount, _unit), do: nil

	defp rate_config(overrides \\ []) do
		configured = Application.get_env(:marketmailer, :esi_rate_limit, [])
		configured = if is_list(configured), do: configured, else: []

		@rate_defaults
		|> Keyword.merge(configured)
		|> Keyword.merge(overrides)
	end

	defp rate_table?, do: :ets.whereis(@rate_table) != :undefined

	defp remain(value), do: parse_int(value) || 999
	defp first(val, key), do: val |> Map.get(key, []) |> List.first()

	defp enforce_pause(ttl) do
		now = System.system_time(:millisecond)
		:ets.insert(@table, {@key, now + @pause_ms})
		max(ttl, @pause_ms)
	end

	defp calc_ttl(nil), do: 60_000

	defp calc_ttl(exp) do
		case :httpd_util.convert_request_date(to_charlist(exp)) do
			{{_, _, _}, {_, _, _}} = erl ->
				datetime = DateTime.from_naive!(NaiveDateTime.from_erl!(erl), "Etc/UTC")
				max(DateTime.diff(datetime, DateTime.utc_now(), :millisecond), 5_000) + 1_000

			_ ->
				60_000
		end
	end

	defp parse_int(nil), do: nil

	defp parse_int(value) do
		case Integer.parse(to_string(value)) do
			{int, _} -> int
			:error -> nil
		end
	end

	def retry_after_ms(headers) do
		case first(headers, "retry-after") do
			nil ->
				0

			value ->
				case Float.parse(String.trim(to_string(value))) do
					{secs, ""} -> round(secs * 1000)
					_ -> 0
				end
		end
	end

	defp configured_http_fun do
		Application.get_env(:marketmailer, :esi_http_fun, &Req.get/2)
	end
end
