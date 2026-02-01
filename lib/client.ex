defmodule Marketmailer.Client do
  use GenServer
  require Logger

  @table_name :market_etags
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

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  ## GenServer callbacks

  @impl true
  def init(state) do
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    send(self(), :check_schedule)
    {:ok, state}
  end

  @impl true
  def handle_info(:work, state) do
    work()
    {:noreply, state}
  end

  ## Internal

  defp work() do
    @regions
    |> Task.async_stream(
      fn region_id -> fetch_region(region_id) end,
      max_concurrency: System.schedulers_online(),
      timeout: @work_interval
    )
    |> Stream.run()

    Process.send_after(self(), :work, @work_interval)
  end

  defp fetch_region(region_id) do
    url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/"

    case fetch_page(url, region_id, 1) do
      :not_modified ->
        :ok

      {:ok, response} ->
        pages =
          response.headers["x-pages"]
          |> List.first()
          |> String.to_integer()

        if pages > 1 do
          2..pages
          |> Task.async_stream(
            fn page ->
              page_url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"
              fetch_page(page_url, region_id, page)
            end,
            max_concurrency: System.schedulers_online() * 2,
            timeout: @work_interval
          )
          |> Stream.run()
        end

        :ok

      {:error, reason} ->
        IO.warn("#{region_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp fetch_page(url, region_id, page_number) do
    page_etag = get_etag_with_fallback(url)

    headers = if page_etag, do: [{"If-None-Match", page_etag}], else: []

    case Req.get(url, headers: headers) do
      {:ok, %{status: 304}} ->
        IO.puts("Region #{region_id} page #{page_number}: 304")
        :not_modified

      {:ok, %{status: status} = response} when status in 200..299 ->
        #  Sun, 01 Feb 2026 04:39:07 GMT
        expiry = List.first(response.headers["expires"])

        total_seconds =
          expiry
          |> String.to_charlist()
          |> :httpd_util.convert_request_date()
          |> NaiveDateTime.from_erl!()
          |> DateTime.from_naive!("Etc/UTC")
          |> DateTime.diff(DateTime.utc_now(), :second)
          |> max(0)

        hours = div(total_seconds, 3600)
        minutes = div(rem(total_seconds, 3600), 60)
        seconds = rem(total_seconds, 60)

        formatted =
          :io_lib.format("~2..0b:~2..0b:~2..0b", [hours, minutes, seconds]) |> List.to_string()

        new_etag = List.first(response.headers["etag"])

        if new_etag, do: save_etag(url, new_etag)

        orders = response.body

        upsert_orders(orders, url, new_etag)

        IO.puts(
          "#{status} #{region_id} page #{page_number} \t #{length(orders)} orders \t #{formatted} #{new_etag}"
        )

        {:ok, response}

      {:ok, response} ->
        IO.warn("Unexpected status: #{response.status}")
        {:error, response.status}

      {:error, reason} ->
        {:error, reason}
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
