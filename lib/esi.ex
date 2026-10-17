defmodule ESI do
	@user_agent "lostcoastwizard > BEAM me up, Scotty!"
	@maint_key :maintenance_mode
	@maint_ping_ms 10_000
	@error_limit_threshold 100
	@pause_ms 61_000
	@table :esi_error_state
	@key :blocked_until

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

	def page_url(region, page \\ 1), do: "https://esi.evetech.net/v1/markets/#{region}/orders/?page=#{page}"

	def fetch(region, page \\ 1, opts \\ []) do
		url = page_url(region, page)
		http_fun = Keyword.get(opts, :http_fun, &Req.get/2)
		etag = Etag.Database.get_etag(url)

		headers =
			[{"User-Agent", @user_agent}] ++
				if etag, do: [{"If-None-Match", etag}], else: []

		case http_fun.(url, headers: headers, pool_timeout: :infinity, retry_log_level: :info) do
			{:ok, response} ->
				respond(response, url)

			{:error, error} ->
				Marketmailer.Log.error(
					"esi_http_error",
					%{region: region, page: page, error: inspect(error)},
					"#{region}/#{page} HTTP error: #{inspect(error)}"
				)

				{:error, error}
		end
	end

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

		%{
			url: url,
			etag: first(response.headers, "etag"),
			ttl: ttl,
			expires_at: now + ttl,
			pages: parse_int(first(response.headers, "x-pages")) || 1,
			retry_after_ms: retry_after_ms(response.headers)
		}
	end

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
end
