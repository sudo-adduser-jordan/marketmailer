defmodule ESI do
	require Logger

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
				Logger.warning("ESI limit low, pausing #{div(sleep, 1000)}s")
				Process.sleep(sleep)

			_ ->
				:ok
		end
	end

	def fetch(region, page \\ 1) do
		url = "https://esi.evetech.net/v1/markets/#{region}/orders/?page=#{page}"
		etag = Market.Database.get_etag(url)

		headers =
			[{"User-Agent", @user_agent}] ++
				if etag, do: [{"If-None-Match", etag}], else: []

		# review
		case Req.get(url, headers: headers, pool_timeout: :infinity) do
			{:ok, %{status: 200} = response} ->
				clear_maintenance()
				{:ok, response.body, meta(response, url)}

			{:ok, %{status: 304} = response} ->
				clear_maintenance()
				{:not_modified, meta(response, url)}

			{:ok, %{status: 503} = response} ->
				activate_maintenance()
				{:error, :service_unavailable, meta(response, url)}

			{:ok, response} ->
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
			pages: String.to_integer(first(response.headers, "x-pages") || "1")
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
end
