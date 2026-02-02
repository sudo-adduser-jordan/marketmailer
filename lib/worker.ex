defmodule Marketmailer.RegionWorker do
  use GenServer, restart: :transient
  require Logger

  @table_name :market_etags

  def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))

  defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

  @impl true
  def init(region_id) do
    send(self(), :work)
    {:ok, %{region_id: region_id}}
  end

  @impl true
  def handle_info(:work, %{region_id: region_id} = state) do
    delay = sync_region(region_id)
    Process.send_after(self(), :work, delay + 2000)
    {:noreply, state}
  end

  defp sync_region(id) do
    case request(id, 1) do
      {:ok, %{ttl: ttl, pages: pages}} ->
        if pages > 1, do: spawn_pages(id, pages)
        ttl

      _ ->
        60_000
    end
  end

  defp spawn_pages(id, total),
    do:
      Task.async_stream(2..total, &request(id, &1), max_concurrency: System.schedulers_online())
      |> Stream.run()

  defp request(id, page) do
    url = "https://esi.evetech.net/v1/markets/#{id}/orders/?page=#{page}"
    etag = etag_lookup(url)
    headers = if etag, do: [{"if-none-match", etag}], else: []

    with {:ok, response} <- Req.get(url, headers: headers) do
      handle_response(response, id, page, url)
    end
  end

  defp handle_response(%{status: 200} = response, id, page, url) do
    etag = List.first(Req.Response.get_header(response, "etag"))
    if etag, do: :ets.insert(@table_name, {url, etag})

    ttl = parse_ttl(response)
    # upsert_orders(response.body, url, ttl)

    Logger.info(
      "200 #{id} page #{page} \t #{length(response.body)} orders  \t #{format_ttl(ttl)} #{etag}"
    )

    {:ok, %{ttl: ttl, pages: get_pages(response)}}
  end

  defp handle_response(%{status: 304}, id, page, _),
    do:
      (
        Logger.info("304 #{id} Page #{page}")
        {:ok, %{ttl: 20_000, pages: 1}}
      )

  defp handle_response(response, id, _, _),
    do:
      (
        Logger.error("Error #{response.status} on #{id}")
        {:error, response.status}
      )

  defp get_pages(response),
    do: response |> Req.Response.get_header("x-pages") |> List.first("1") |> String.to_integer()

  defp etag_lookup(url) do
    case :ets.lookup(@table_name, url) do
      [{_, etag}] -> etag
      _ -> nil
    end
  end

  defp parse_http_date(date_str) do
    case date_str |> String.to_charlist() |> :httpd_util.convert_request_date() do
      :bad_date ->
        :error

      {{_, _, _}, {_, _, _}} = erl_datetime ->
        dt =
          erl_datetime
          |> NaiveDateTime.from_erl!()
          |> DateTime.from_naive!("Etc/UTC")

        {:ok, dt}
    end
  end

  defp parse_ttl(response) do
    with [expiry_str] <- response.headers["expires"],
         {:ok, expiry_dt} <- parse_http_date(expiry_str) do
      diff = DateTime.diff(expiry_dt, DateTime.utc_now(), :millisecond)
      # If the clock is slightly off or it's already expired,
      # default to a 1-second "retry" wait.
      max(diff, 1000)
    else
      # Default to 5 mins if header is missing
      _ ->
        Logger.error("Missing expires header")
        300_000
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

  # defp upsert_orders(orders, _url, _etag) do
  #   timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  #   # Define exactly what should be updated if an order_id already exists.
  #   # exclude :inserted_at so we keep the original "first seen" date.
  #   fields_to_update = [
  #     :duration,
  #     :is_buy_order,
  #     :issued,
  #     :location_id,
  #     :min_volume,
  #     :price,
  #     :range,
  #     :system_id,
  #     :type_id,
  #     :volume_remain,
  #     :volume_total,
  #     :updated_at
  #   ]

  #   entries =
  #     Enum.map(orders, fn order ->
  #       order
  #       |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
  #       |> Map.merge(%{inserted_at: timestamp, updated_at: timestamp})
  #     end)

  #   entries
  #   |> Enum.chunk_every(500)
  #   |> Enum.each(fn chunk ->
  #     Marketmailer.Database.insert_all(
  #       Market,
  #       chunk,
  #       on_conflict: {:replace, fields_to_update},
  #       conflict_target: :order_id
  #     )
  #   end)
  # end
end
