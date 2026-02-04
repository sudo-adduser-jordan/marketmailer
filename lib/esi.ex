defmodule Marketmailer.ESI do
  require Logger

  def fetch(region_id, page \\ 1) do
    url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"

    etag =
      case :ets.lookup(:market_cache, url) do
        [{_, val}] -> val
        _ -> nil
      end

    headers = if etag, do: [{"if-none-match", etag}], else: []

    case Req.get(url, headers: headers,pool_timeout: :infinity) do
      {:ok, %{status: 200} = resp} ->
        new_etag = resp.headers["etag"] |> List.first()
        if new_etag, do: :ets.insert(:market_cache, {url, new_etag})

        meta = parse_metadata(resp, url)

        Logger.info(
          "200 #{region_id} page #{page} \t #{length(resp.body)} orders  \t #{format_ttl(meta.ttl)} #{new_etag}"
        )

        {:ok, resp.body, meta}

      {:ok, %{status: 304} = resp} ->
        meta = parse_metadata(resp, url)

        Logger.info(
          "200 #{region_id} page #{page} \t #{format_ttl(meta.ttl)}"
        )

        {:not_modified, parse_metadata(resp, url)}

      {:ok, resp} ->
        {:error, resp.status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_metadata(resp, url) do
    # Get the header value first
    raw_pages = resp.headers["x-pages"] |> List.first()
    etag = resp.headers["etag"] |> List.first()

    %{
      pages: if(raw_pages, do: String.to_integer(raw_pages), else: 1),
      ttl: calculate_ttl(resp.headers["expires"] |> List.first()),
      # Matches the key the worker is looking for
      url: url,
      # Matches the key the worker is looking for
      etag: etag
    }
  end

  defp calculate_ttl(nil), do: 300_000

  defp calculate_ttl(expires) do
    with {{_, _, _}, {_, _, _}} = erl_dt <-
           :httpd_util.convert_request_date(String.to_charlist(expires)),
         dt <- DateTime.from_naive!(NaiveDateTime.from_erl!(erl_dt), "Etc/UTC") do
      max(DateTime.diff(dt, DateTime.utc_now(), :millisecond), 5000)
    else
      _ -> 60_000
    end
  end

  defp format_ttl(ttl_ms) do
    total_seconds = div(ttl_ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    "~2..0B:~2..0B"
    |> :io_lib.format([minutes, seconds])
    |> List.to_string()
  end

end
