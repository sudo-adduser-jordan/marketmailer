defmodule Marketmailer.Client do
  use GenServer

  # https://esi.evetech.net/markets/{region_id}/orders
  @orders_base_url "https://esi.evetech.net/markets"
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

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Load etags from DB on startup
    # etags = load_etags_from_db()
    # state = Map.put(state, :etags, etags)

    etags = %{}
    state = Map.put(state, :etags, etags)

    work(state)
    # {new_state, _results} = work(state)
    schedule_work()
    {:ok, state}
    # {:ok, new_state}
  end

  @impl true
  def handle_info(:work, state) do
    {new_state, _} = work(state)

    # Sync etags back to DB
    # if new_state.etags != state.etags do
    #   save_etags_to_db(new_state.etags)
    # end

    schedule_work()
    {:noreply, new_state}
  end

  defp schedule_work do
    Process.send_after(self(), :work, @work_interval)
  end

  # defp work(%{etags: etags} = state) do
  defp work(_state) do

  @regions |> Task.async_stream(fn region_id ->

    response = "https://esi.evetech.net/v1/markets/#{region_id}/orders/"
    |> Req.get!()

    pages = response.headers["x-pages"]
    |> List.first()
    |> String.to_integer()

    etag = response.headers["etag"]
    |> List.first()

    page_urls = if pages > 1 do
      for page <- 2..pages do "https://esi.evetech.net/v1/markets/#{region_id}/orders?page=#{page}" end
    else [] end

    page_urls |> IO.inspect(label: "\n Region: #{region_id} \n\t Etag: #{etag} \n\t Orders: #{length(response.body)} \n\t Pages: #{pages} \n ")

    end,
      max_concurrency: System.schedulers_online() * 4,
      timeout: @work_interval
  ) |> Enum.to_list()

    # stream_results =
    #   Task.async_stream(
    #     urls,
    #     fn {url, _} = page_info ->
    #       fetch_orders_url(page_info, Map.get(etags, url))
    #     end,
    #     max_concurrency: max_concurrency,
    #     timeout: @work_interval
    #   )

    # results = Enum.to_list(stream_results)

    # updated_etags =
    #   Enum.reduce(results, etags, fn
    #     {:ok, {:ok, url, new_etag}}, acc ->
    #       Map.put(acc, url, new_etag)

    #     {:ok, {:not_modified, url, new_etag}}, acc ->
    #       Map.put(acc, url, new_etag)

    #     {:ok, {:error, _url, _reason}}, acc ->
    #       acc

    #     _other, acc ->
    #       acc
    #   end)

    # {%{state | etags: updated_etags}, results}
  end

  defp fetch_first_page(region_id) do
    Req.get(page_url(region_id, 1), params: [order_type: "all"])
  end

  defp page_url(region_id, page) do
    "#{@orders_base_url}/#{region_id}/orders/?order_type=all&page=#{page}" |> IO.inspect() |> to_string()
  end

  defp process_first_page(orders, _url, etag) do
    if orders && length(orders) > 0 do
      # upsert_orders(orders, url, etag || "")
      {:ok, etag}
    else
      :ok
    end
  end

  defp fetch_orders_url({url, _}, current_etag) do
    headers = maybe_put_if_none_match([], current_etag)

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 304, headers: resp_headers}} ->
        new_etag = find_etag(resp_headers) || current_etag
        {:not_modified, url, new_etag}

      {:ok, %Req.Response{status: 200, headers: resp_headers, body: body}}
      when is_list(body) ->
        new_etag = find_etag(resp_headers) || current_etag

        # Upsert orders to keep DB in sync with this exact ETag
        # upsert_orders(body, url, new_etag)
        {:ok, url, new_etag}

      other ->
        IO.inspect(other, label: "Fetch #{url} failed")
        {:error, url, other}
    end
  end

  defp fetch_region_pages(region_id) do
    case fetch_first_page(region_id) do
      {:ok, %Req.Response{status: 200, headers: headers, body: body}} ->
        pages = headers["x-pages"] || "1"
        page_count = String.to_integer(pages)

        # Use first page URL and etag if available, generate others
        first_url = page_url(region_id, 1)
        first_etag = find_etag(headers)

        urls =
          for page <- 1..page_count do
            url = page_url(region_id, page)
            etag = if page == 1 and first_etag, do: first_etag, else: nil
            {url, etag}
          end

        # Process first page data immediately (don't wait for Task)
        case process_first_page(body, first_url, first_etag) do
          {:ok, first_etag} -> {:ok, urls}
          # Still return URLs even if processing fails
          _ -> {:ok, urls}
        end

      other ->
        {:error, other}
    end
  end

  ## DATABASE ETAG SYNC

  # defp load_etags_from_db do
  #   case Marketmailer.Database.all(Etag) do
  #     {:ok, etag_records} ->
  #       etag_records
  #       |> Enum.into(%{}, fn record ->
  #         {record.url, record.etag}
  #       end)

  #     {:error, _} ->
  #       %{}
  #   end
  # end

  # defp save_etags_to_db(etags) do
  #   etag_list =
  #     Map.to_list(etags)
  #     |> Enum.map(fn {url, etag} ->
  #       [url: url, etag: etag]
  #     end)

  #   # Upsert etags (delete old, insert new)
  #   Marketmailer.Database.delete_all(Etag)
  #   Marketmailer.Database.insert_all(Etag, etag_list)
  # end

  defp upsert_orders(orders, url, etag) do
    order_list =
      orders
      |> Enum.map(fn order ->
        order_map = [
          order_id: order["order_id"],
          type_id: order["type_id"],
          price: order["price"],
          volume_remain: order["volume_remain"],
          volume_total: order["volume_total"],
          duration: order["duration"],
          is_buy_order: order["is_buy_order"],
          issued: order["issued"],
          location_id: order["location_id"],
          min_volume: order["min_volume"],
          range: order["range"],
          system_id: order["system_id"]
        ]

        # Convert list of tuples to map
        map = Map.new(order_map)

        # Add etag_url and etag_value to keep orders in sync with their source
        map = Map.put(map, :etag_url, url)
        map = Map.put(map, :etag_value, etag)

        map
      end)

    # Upsert: delete orders from this URL first, then insert fresh
    # Marketmailer.Database.delete_by(Market, etag_url: url)

    order_list
    |> Enum.chunk_every(2048)
    |> Enum.each(fn chunk ->
      Marketmailer.Database.insert_all(Market, chunk)
    end)
  end

  ## Helpers

  defp maybe_put_if_none_match(headers, nil), do: headers
  defp maybe_put_if_none_match(headers, etag), do: [{"If-None-Match", etag} | headers]

  defp find_etag(headers) do
    headers
    |> Enum.find_value(fn
      {"etag", v} -> v
      {"ETag", v} -> v
      _ -> nil
    end)
  end
end

# # migration
# create table(:markets) do
#   add :order_id, :bigint, primary_key: true
#   add :type_id, :bigint
#   add :price, :decimal
#   add :volume_remain, :bigint
#   add :volume_total, :bigint
#   add :duration, :integer
#   add :is_buy_order, :boolean
#   add :issued, :naive_datetime
#   add :location_id, :bigint
#   add :min_volume, :bigint
#   add :range, :string
#   add :system_id, :bigint
#   add :etag_url, :text  # Links order to its source page
#   add :etag_value, :text  # Links order to its ETag
# end

# create table(:etags) do
#   add :url, :text, primary_key: true
#   add :etag, :text
# end
