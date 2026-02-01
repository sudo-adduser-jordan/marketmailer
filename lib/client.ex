defmodule Marketmailer.Client do
  use GenServer

  # 5 minutes
  @work_interval 300_000
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
    # etags: %{url => etag_string} # move to database
    state = Map.put(state, :etags, %{})
    work(state)
    Process.send_after(self(), :work, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:work, state) do
    work(state)
    Process.send_after(self(), :work, @work_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:etag_updated, url, etag}, state) do
    new_etags = Map.put(state.etags, url, etag)
    {:noreply, %{state | etags: new_etags}}
  end

  ## Internal

  defp work(state) do
    etags_snapshot = state.etags

    @regions
    |> Task.async_stream(
      fn region_id -> fetch_region(region_id, etags_snapshot) end,
      max_concurrency: System.schedulers_online(),
      timeout: @work_interval
    )
    |> Stream.run()

    :ok
  end

  defp fetch_region(region_id, etags) do

    case fetch_page("https://esi.evetech.net/v1/markets/#{region_id}/orders/", etags, region_id, 1) do
      :not_modified ->
        IO.puts("Region #{region_id}: 304 (no changes)")
        # No changes for this region.
        :ok

      {:ok, response} ->
        pages =
          response.headers["x-pages"]
          |> List.first()
          |> String.to_integer()

        # orders = response.body
        # upsert_orders(orders, url, new_etag)

        if pages > 1 do
          2..pages
          |> Task.async_stream(
            fn page ->
              page_url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"
              fetch_page(page_url, etags, region_id, page)
            end,
            max_concurrency: System.schedulers_online() * 64,
            timeout: @work_interval
          )
          |> Stream.run()
        end
        :ok

      {:error, reason} ->
        IO.warn("Failed to fetch region #{region_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp fetch_page(url, etags, region_id, page_number) do
    page_etag = Map.get(etags, url)
    headers = if page_etag, do: [{"If-None-Match", page_etag}], else: []
    response = Req.get!(url, headers: headers)

    cond do
      response.status == 304 ->
        # No changes for THIS URL.
        IO.puts("Region #{region_id} page #{page_number}: 304 (no changes)")
        :not_modified

      response.status in 200..299 ->
        new_etag =
          response.headers["etag"]
          |> List.first()

        if is_binary(new_etag) do
          GenServer.cast(__MODULE__, {:etag_updated, url, new_etag})
        end

        orders = response.body

        # per-page upsert, tied to THIS url + THIS etag
        # upsert_orders(orders, url, new_etag)

        IO.puts(
          "#{response.status} #{region_id} page #{page_number} \t #{length(orders)} orders \t #{new_etag}"
        )

        {:ok, response}

      true ->
        IO.warn(
          "Region #{region_id} page #{page_number}: unexpected status #{response.status} for #{url}"
        )

        {:error, {:unexpected_status, response.status}}
    end
  end

end
