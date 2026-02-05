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


    # handle 503, handle 404 halt and only ping for status
    case Req.get(url, headers: headers, pool_timeout: :infinity) do
      {:ok, %{status: 200} = response} ->
        new_etag = response.headers["etag"] |> List.first()
        if new_etag, do: :ets.insert(:market_cache, {url, new_etag})

        meta = parse_metadata(response, url)

        Logger.info(
          "#{response.status} #{region_id} page #{page} \t #{length(response.body)} orders  \t #{format_ttl(meta.ttl)} #{url}"
        )

        {:ok, response.body, meta}

      {:ok, %{status: 304} = response} ->
        meta = parse_metadata(response, url)
        Logger.info("#{response.status} #{region_id} page #{page} \t #{format_ttl(meta.ttl)} #{url}")
        {:not_modified, meta}

      {:ok, response} ->
        meta = parse_metadata(response, url)
        Logger.info("#{response.status} #{region_id} page #{page} \t #{format_ttl(meta.ttl)} #{url}")
        {:error, response.status}

      {:error, reason} ->
        Logger.info("Error: #{reason}")
        {:error, reason}
    end
  end

  defp parse_metadata(response, url) do
    raw_pages = response.headers["x-pages"] |> List.first()
    %{
      url: url,
      etag: response.headers["etag"] |> List.first(),
      ttl: calculate_ttl(response.headers["expires"] |> List.first()),
      pages: if(raw_pages, do: String.to_integer(raw_pages), else: 1)
    }
  end

  defp calculate_ttl(nil) do
    60_000
  end

  defp calculate_ttl(expires) do
    with {{_, _, _}, {_, _, _}} = erl_dt <-
           :httpd_util.convert_request_date(String.to_charlist(expires)),
         datetime <- DateTime.from_naive!(NaiveDateTime.from_erl!(erl_dt), "Etc/UTC") do
      max(DateTime.diff(datetime, DateTime.utc_now(), :millisecond), 5000)
    else
      _ ->
        60000
    end
  end

  defp format_ttl(ttl_ms) do
    total_seconds = div(ttl_ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    # Using string interpolation and padding
    m = String.pad_leading("#{minutes}", 2, "0")
    s = String.pad_leading("#{seconds}", 2, "0")

    "#{m}:#{s}"
  end

  # defp format_ttl(ttl_ms) do
  #   total_seconds = div(ttl_ms, 1000)
  #   minutes = div(total_seconds, 60)
  #   seconds = rem(total_seconds, 60)

  #   "~2..0B:~2..0B"
  #   |> :io_lib.format([minutes, seconds])
  #   |> List.to_string()
  # end
end
