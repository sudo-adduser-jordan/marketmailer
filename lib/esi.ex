defmodule ESI do
	require Logger

	@user_agent "lostcoastwizard > BEAM me up, Scotty!"
	@maint_key :maintenance_mode
	@maint_ping_ms 10_000
	@error_limit_threshold 100
	@pause_ms 61_000
	@table :esi_error_state
	@key :blocked_until

	# New floating-window rate limiting (X-Ratelimit-* headers), active on some
	# routes. The old x-esi-error-limit-* handling stays for the others; the two
	# header families are mutually exclusive.
	@token_cost 2
	@unknown_group :unknown
	@default_limit 150
	@default_window_ms 15 * 60_000
	@margin_ms 1_500
	@min_block_ms 1_000

	# Old error-limit handling; still active on routes without the new limiter.
	def wait_for_error_window do
		now = System.system_time(:millisecond)

		case :ets.lookup(@table, @key) do
			[{@key, t}] when t > now ->
				sleep = t - now
				Logger.warning("ESI limit low, pausing #{div(sleep, 1000)}s")
				Process.sleep(sleep)

			_ ->
				:ok
		end
	end

	# --- New rate limiting -------------------------------------------------
	# All unauthenticated calls from this IP share ESI's token buckets (one per
	# rate limit group + source IP), so state is process-wide in @table.

	# Reserve tokens for one request against the bucket of the group the url
	# belongs to. The group is learned from a prior response's X-Ratelimit-Group
	# header (or a shared :unknown bucket before that). Sleeps until tokens are
	# available so concurrent page workers self-throttle instead of bursting.
	def acquire(url, cost \\ @token_cost) do
		group = group_for(url)
		wait_blocked(group)
		acquire_bucket(group, cost)
	end

	# Feed server truth back into the ledger after a response. A 429 parks the
	# group bucket via Retry-After; other statuses correct X-Ratelimit-Remaining.
	def release(headers, url) do
		case rate_meta(headers) do
			nil ->
				:ok

			rate ->
				group = rate.group || group_for(url)
				retry = retry_after_ms(headers)

				if retry > 0 do
					now = System.system_time(:millisecond)
					:ets.insert(@table, {{:blocked, group}, now + max(retry, @min_block_ms) + @margin_ms})
					:ok
				else
					record_bucket(group, url, rate)
				end
		end
	end

	def fetch(region, page \\ 1) do
		url = "https://esi.evetech.net/v1/markets/#{region}/orders/?page=#{page}"
		acquire(url)
		etag = Etag.Database.get_etag(url)

		headers =
			[{"User-Agent", @user_agent}] ++
				if etag, do: [{"If-None-Match", etag}], else: []

		case Req.get(url, headers: headers, pool_timeout: :infinity) do
			{:ok, %{status: 200} = response} ->
				clear_maintenance()
				release(response.headers, url)
				{:ok, response.body, meta(response, url)}

			{:ok, %{status: 304} = response} ->
				clear_maintenance()
				release(response.headers, url)
				{:not_modified, meta(response, url)}

			{:ok, %{status: 429} = response} ->
				release(response.headers, url)
				{:error, :rate_limited, meta(response, url)}

			{:ok, %{status: 503} = response} ->
				activate_maintenance()
				{:error, :service_unavailable, meta(response, url)}

			{:ok, response} ->
				release(response.headers, url)
				_ = meta(response, url)
				{:error, response.status}

			{:error, error} ->
				Logger.error("#{region}/#{page} HTTP error: #{inspect(error)}")
				{:error, error}
		end
	end

	# Set a timestamp 10s in the future
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

		%{
			url: url,
			etag: first(response.headers, "etag"),
			ttl: ttl,
			pages: String.to_integer(first(response.headers, "x-pages") || "1"),
			retry_after_ms: retry_after_ms(response.headers)
		}
	end

	defp remain(nil), do: 999
	defp remain(value), do: value |> Integer.parse() |> elem(0)
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

	# --- New-rate-limit internals ------------------------------------------

	defp group_for(url) do
		case :ets.lookup(@table, {:url_group, url}) do
			[{_, group}] -> group
			_ -> @unknown_group
		end
	end

	defp wait_blocked(group) do
		now = System.system_time(:millisecond)

		case :ets.lookup(@table, {:blocked, group}) do
			[{_, t}] when t > now ->
				sleep = t - now
				Logger.warning("ESI rate-limited, waiting #{div(sleep, 1000)}s")
				Process.sleep(sleep)
				wait_blocked(group)

			_ ->
				:ok
		end
	end

	defp acquire_bucket(group, cost) do
		now = System.system_time(:millisecond)

		case :ets.lookup(@table, {:bucket, group}) do
			[] ->
				# Nothing learned for this group yet: seed a conservative bucket so
				# the initial sweep self-throttles instead of stampeding into 429s.
				:ets.insert(@table, {{:bucket, group}, max(@default_limit - cost, 0), now, @default_limit, @default_window_ms})
				:ok

			[{{:bucket, ^group}, tokens, last, limit, window}] ->
				refill_rate = limit / window
				available = min(limit, tokens + (now - last) * refill_rate)

				if available >= cost do
					:ets.insert(@table, {{:bucket, group}, available - cost, now, limit, window})
					:ok
				else
					needed = cost - available
					sleep = if(refill_rate > 0, do: round(needed / refill_rate), else: @pause_ms) + @margin_ms
					Process.sleep(sleep)
					acquire_bucket(group, cost)
				end
		end
	end

	defp record_bucket(group, url, %{remaining: remaining, limit: limit, window_ms: window})
			 when is_integer(remaining) and is_integer(limit) and limit > 0 and window > 0 do
		now = System.system_time(:millisecond)
		:ets.insert(@table, {{:bucket, group}, min(remaining, limit), now, limit, window})
		:ets.insert(@table, {{:url_group, url}, group})
		:ok
	end

	defp record_bucket(_group, _url, _rate), do: :ok

	defp rate_meta(headers) do
		case first(headers, "x-ratelimit-limit") do
			nil ->
				nil

			limit ->
				{tokens, window} = parse_limit(limit)

				%{
					group: first(headers, "x-ratelimit-group"),
					remaining: parse_int(first(headers, "x-ratelimit-remaining")),
					used: parse_int(first(headers, "x-ratelimit-used")),
					limit: tokens,
					window_ms: window
				}
		end
	end

	defp parse_limit(limit) do
		case String.split(to_string(limit), "/") do
			[tokens, unit] ->
				case Regex.run(~r/(\d+)([mh])/, unit) do
					[_, n, "m"] -> {parse_int(tokens) || @default_limit, String.to_integer(n) * 60_000}
					[_, n, "h"] -> {parse_int(tokens) || @default_limit, String.to_integer(n) * 3_600_000}
					_ -> {@default_limit, @default_window_ms}
				end

			_ ->
				{parse_int(limit) || @default_limit, @default_window_ms}
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
end
