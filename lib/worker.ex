defmodule Marketmailer.RegionWorker do
  use GenServer, restart: :transient

  @table_name :market_etags

  def start_link(region_id) do
    GenServer.start_link(__MODULE__, region_id, name: via_tuple(region_id))
  end

  defp via_tuple(region_id), do: {:via, Registry, {Marketmailer.Registry, {:region, region_id}}}

  @impl true
  def init(region_id) do
    send(self(), :work)
    {:ok, %{region_id: region_id}}
  end

  @impl true
  def handle_info(:work, %{region_id: region_id} = state) do
    delay = fetch_region(region_id)
    Process.send_after(self(), :work, delay + 2000)
    {:noreply, state}
  end

  # defp fetch_region(region_id) do
  #   url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/"

  #   case fetch_page(url, region_id, 1) do
  #     {:ok, %{ttl: ttl}} ->
  #       ttl

  #     # Default to 1 min retry on error/304
  #     _ ->
  #       60_000
  #   end
  # end

  defp fetch_region(region_id) do
    url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/"

    case fetch_page(url, region_id, 1) do
      {:ok, %{ttl: ttl, total_pages: total_pages}} ->
        # ALWAYS spawn for pages 2..N
        if total_pages > 1 do
          spawn_pagination_tasks(region_id, total_pages)
        end

        ttl

      _ ->
        60_000
    end
  end

  # defp fetch_page(url, region_id, page_number) do
  #   etag = get_etag_with_fallback(url)
  #   headers = if etag, do: [{"If-None-Match", etag}], else: []

  #   case Req.get(url, headers: headers) do
  #     {:ok, %{status: 304} = res} ->
  #       IO.puts("304 #{region_id} page #{page_number}")
  #       {:ok, %{ttl: calculate_ttl(res)}}

  #     {:ok, %{status: 200} = res} ->
  #       new_etag =
  #         res.headers
  #         |> Map.get("etag", [])
  #         |> List.first()

  #       if new_etag, do: save_etag(url, new_etag)

  #       # upsert_orders(res.body, url, new_etag)

  #       if page_number > 1 do
  #         spawn_pagination_tasks(res, region_id)
  #       end

  #       ttl = calculate_ttl(res)

  #       total_seconds = div(ttl, 1000)
  #       minutes = div(total_seconds, 60)
  #       seconds = rem(total_seconds, 60)

  #       formatted_time =
  #         "~2..0B:~2..0B"
  #         |> :io_lib.format([minutes, seconds])
  #         |> List.to_string()

  #       ttl = 20000

  #       IO.puts(
  #         "200 #{region_id} page #{page_number} \t #{length(res.body)} orders \t #{ttl} #{new_etag}"
  #       )

  #       {:ok, %{ttl: ttl}}

  #     {:error, _} ->
  #       :error
  #   end
  # end

  defp fetch_page(url, region_id, page_number) do
    etag = get_etag_with_fallback(url)
    headers = if etag, do: [{"If-None-Match", etag}], else: []

    case Req.get(url, headers: headers) do
      {:ok, res} when res.status in [200, 304] ->
        # Extract pages count
        total_pages =
          case Req.Response.get_header(res, "x-pages") do
            [val | _] -> String.to_integer(val)
            [] -> 1
          end

        if res.status == 200 do
          # To this (cleaner and solves the warning):
          case Req.Response.get_header(res, "etag") do
            [etag_value | _] -> save_etag(url, etag_value)
            [] -> :ok
          end

          # new_etag = List.first(Req.Response.get_header(res, "etag") || [])
          # if new_etag, do: save_etag(url, new_etag)
          IO.puts("200 #{region_id} page #{page_number} - New Data")
        else
          IO.puts("304 #{region_id} page #{page_number} - No Change")
        end

        # Return the total_pages so we can use it even on 304
        # {:ok, %{ttl: calculate_ttl(res), total_pages: total_pages}}
        {:ok, %{ttl: 20000, total_pages: total_pages}}

      {:error, reason} ->
        IO.inspect(reason, label: "Fetch Error")
        :error
    end
  end

  # defp spawn_pagination_tasks(response, region_id) do
  #   pages_header = List.first(response.headers["x-pages"] || ["1"])
  #   total_pages = String.to_integer(pages_header)

  #   if total_pages > 1 do
  #     # Task.async_stream to fetch pages 2..N in parallel.
  #     2..total_pages
  #     |> Task.async_stream(
  #       fn page ->
  #         page_url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"
  #         fetch_page(page_url, region_id, page)
  #       end,
  #       timeout: 60_000,
  #       max_concurrency: System.schedulers_online()
  #     )
  #     |> Stream.run()
  #   end
  # end

  defp spawn_pagination_tasks(region_id, total_pages) do
    2..total_pages
    |> Task.async_stream(
      fn page ->
        page_url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"
        fetch_page(page_url, region_id, page)
      end,
      # High timeout because 400+ pages can take a while
      timeout: 120_000,
      max_concurrency: 20
    )
    |> Stream.run()
  end

  defp calculate_ttl(response) do
    with [expiry_str] <- response.headers["expires"],
         {:ok, expiry_dt} <- parse_http_date(expiry_str) do
      diff = DateTime.diff(expiry_dt, DateTime.utc_now(), :millisecond)
      # If the clock is slightly off or it's already expired,
      # default to a 1-second "retry" wait.
      max(diff, 1000)
    else
      # Default to 5 mins if header is missing
      _ ->
        IO.inspect("Missing expires header")
        300_000
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

  defp upsert_orders(orders, _url, _etag) do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Define exactly what should be updated if an order_id already exists.
    # exclude :inserted_at so we keep the original "first seen" date.
    fields_to_update = [
      :duration,
      :is_buy_order,
      :issued,
      :location_id,
      :min_volume,
      :price,
      :range,
      :system_id,
      :type_id,
      :volume_remain,
      :volume_total,
      :updated_at
    ]

    entries =
      Enum.map(orders, fn order ->
        order
        |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
        |> Map.merge(%{inserted_at: timestamp, updated_at: timestamp})
      end)

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Marketmailer.Database.insert_all(
        Market,
        chunk,
        on_conflict: {:replace, fields_to_update},
        conflict_target: :order_id
      )
    end)
  end

  # Multi-layered retrieval
  defp get_etag_with_fallback(url) do
    case :ets.lookup(@table_name, url) do
      [{^url, etag}] ->
        etag

      [] ->
        #   # Check DB if not in memory (useful after a restart)
        #   case Marketmailer.Database.get(Etag, url) do
        # nil ->
        nil

        #     record ->
        #       # Warm the cache
        #       :ets.insert(@table_name, {url, record.etag})
        #       record.etag
        #   end
    end
  end

  # Multi-layered storage
  defp save_etag(url, etag) do
    # Update Memory
    :ets.insert(@table_name, {url, etag})

    # Update DB (Upsert)
    # %Etag{url: url}
    # |> Etag.changeset(%{etag: etag})
    # |> Marketmailer.Database.insert(
    #   on_conflict: [set: [etag: etag]],
    #   conflict_target: :url
    # )
  end
end
