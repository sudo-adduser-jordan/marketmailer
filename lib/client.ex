defmodule Marketmailer.RegionDynamicSupervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def start_child(region_id) do
    spec = {Marketmailer.RegionWorker, region_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

defmodule Marketmailer.RegionManager do
  use GenServer

  @regions [
    10_000_001,
    10_000_002,
    10_000_003,
    10_000_004,
    10_000_005,
    10_000_006,
    10_000_007,
    10_000_008,
    10_000_009,
    10_000_010,
    10_000_011,
    10_000_012,
    10_000_013,
    10_000_014,
    10_000_015,
    10_000_016,
    10_000_017,
    10_000_018,
    10_000_019,
    10_000_020,
    10_000_021,
    10_000_022,
    10_000_023,
    10_000_025,
    10_000_027,
    10_000_028,
    10_000_029,
    10_000_030,
    10_000_031,
    10_000_032,
    10_000_033,
    10_000_034,
    10_000_035,
    10_000_036,
    10_000_037,
    10_000_038,
    10_000_039,
    10_000_040,
    10_000_041,
    10_000_042,
    10_000_043,
    10_000_044,
    10_000_045,
    10_000_046,
    10_000_047,
    10_000_048,
    10_000_049,
    10_000_050,
    10_000_051,
    10_000_052,
    10_000_053,
    10_000_054,
    10_000_055,
    10_000_056,
    10_000_057,
    10_000_058,
    10_000_059,
    10_000_060,
    10_000_061,
    10_000_062,
    10_000_063,
    10_000_064,
    10_000_065,
    10_000_066,
    10_000_067,
    10_000_068,
    10_000_069,
    10_000_070,
    10_001_000,
    11_000_001,
    11_000_002,
    11_000_003,
    11_000_004,
    11_000_005,
    11_000_006,
    11_000_007,
    11_000_008,
    11_000_009,
    11_000_010,
    11_000_011,
    11_000_012,
    11_000_013,
    11_000_014,
    11_000_015,
    11_000_016,
    11_000_017,
    11_000_018,
    11_000_019,
    11_000_020,
    11_000_021,
    11_000_022,
    11_000_023,
    11_000_024,
    11_000_025,
    11_000_026,
    11_000_027,
    11_000_028,
    11_000_029,
    11_000_030,
    11_000_031,
    11_000_032,
    11_000_033,
    12_000_001,
    12_000_002,
    12_000_003,
    12_000_004,
    12_000_005,
    14_000_001,
    14_000_002,
    14_000_003,
    14_000_004,
    14_000_005,
    19_000_001
  ]

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    send(self(), {:start_workers, @regions})
    {:ok, %{}}
  end

  @impl true
  def handle_info({:start_workers, []}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:start_workers, [region | rest]}, state) do
    Marketmailer.RegionDynamicSupervisor.start_child(region)
    Process.send_after(self(), {:start_workers, rest}, 100)
    {:noreply, state}
  end
end

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
    # fetch_region now returns the TTL in milliseconds
    delay = fetch_region(region_id)

    # Schedule next run based on ESI's 'expires' header (plus 2s buffer)
    Process.send_after(self(), :work, delay + 2000)

    {:noreply, state}
  end

  defp fetch_region(region_id) do
    url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/"

    case fetch_page(url, region_id, 1) do
      {:ok, %{ttl: ttl}} -> ttl
      # Default to 1 min retry on error/304
      _ -> 60_000
    end
  end

  defp fetch_page(url, region_id, page_number) do
    etag = get_etag_with_fallback(url)
    headers = if etag, do: [{"If-None-Match", etag}], else: []

    case Req.get(url, headers: headers) do
      {:ok, %{status: 304} = res} ->
        {:ok, %{ttl: calculate_ttl(res)}}

      {:ok, %{status: 200} = res} ->
        new_etag =
          res.headers
          |> Map.get("etag", [])
          |> List.first()

        if new_etag, do: save_etag(url, new_etag)

        # Handle Database Insert
        upsert_orders(res.body, url, new_etag)

        # Handle Pagination if it's page 1
        if page_number == 1 do
          spawn_pagination_tasks(res, region_id)
        end

        {:ok, %{ttl: calculate_ttl(res)}}

      {:error, _} ->
        :error
    end
  end

  defp spawn_pagination_tasks(response, region_id) do
    pages_header = List.first(response.headers["x-pages"] || ["1"])
    total_pages = String.to_integer(pages_header)

    if total_pages > 1 do
      # We use Task.async_stream to fetch pages 2..N in parallel.
      # We don't need to return anything here; they just write to the DB/ETS.
      2..total_pages
      |> Task.async_stream(
        fn page ->
          page_url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"
          fetch_page(page_url, region_id, page)
        end,
        max_concurrency: 5,
        timeout: 60_000
      )
      |> Stream.run()
    end
  end

  defp calculate_ttl(response) do
    # httpdate format "Sun, 01 Feb 2026 05:00:00 GMT"
    # expiry = List.first(response.headers["expires"])

    # expiry_dt =
    #   expiry
    #   |> String.to_charlist()
    #   |> :httpd_util.convert_request_date()
    #   |> NaiveDateTime.from_erl!()
    #   |> DateTime.from_naive!("Etc/UTC")

    # # Return milliseconds until expiry
    # DateTime.diff(expiry_dt, DateTime.utc_now(), :millisecond) |> max(0)
    with [expiry_str] <- response.headers["expires"],
         {:ok, expiry_dt} <- parse_http_date(expiry_str) do
      diff = DateTime.diff(expiry_dt, DateTime.utc_now(), :millisecond)
      # If the clock is slightly off or it's already expired,
      # default to a 30-second "retry" wait.
      max(diff, 30_000)
    else
      # Default to 5 mins if header is missing
      _ -> 300_000
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

    # 1. Define exactly what should be updated if an order_id already exists.
    # We exclude :inserted_at so we keep the original "first seen" date.
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
        # Check DB if not in memory (useful after a restart)
        case Marketmailer.Database.get(Etag, url) do
          nil ->
            nil

          record ->
            # Warm the cache
            :ets.insert(@table_name, {url, record.etag})
            record.etag
        end
    end
  end

  # Multi-layered storage
  defp save_etag(url, etag) do
    # Update Memory
    :ets.insert(@table_name, {url, etag})

    # Update DB (Upsert)
    %Etag{url: url}
    |> Etag.changeset(%{etag: etag})
    |> Marketmailer.Database.insert(
      on_conflict: [set: [etag: etag]],
      conflict_target: :url
    )
  end
end
