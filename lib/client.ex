defmodule Marketmailer.Client do
  use GenServer

  @work_interval 300_000
  @orders_base_url "https://esi.evetech.net/latest/markets"
  @regions_url "https://esi.evetech.net/latest/universe/regions/"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Load etags from DB on startup
    etags = load_etags_from_db()
    state = Map.put(state, :etags, etags)

    {new_state, _results} = work(state)
    schedule_work()
    {:ok, new_state}
  end

  @impl true
  def handle_info(:work, state) do
    {new_state, _} = work(state)

    # Sync etags back to DB
    if new_state.etags != state.etags do
      save_etags_to_db(new_state.etags)
    end

    schedule_work()
    {:noreply, new_state}
  end

  defp schedule_work do
    Process.send_after(self(), :work, @work_interval)
  end

  defp work(%{etags: etags} = state) do
    case fetch_regions() do
      {:ok, regions} ->
        urls =
          regions
          |> Enum.flat_map(fn region_id ->
            case fetch_region_pages(region_id) do
              {:ok, pages_info} -> pages_info
              {:error, _} -> []
            end
          end)

        max_concurrency = System.schedulers_online() * 10

        # CONSUME the stream to actually run tasks
        stream_results =
          Task.async_stream(
            urls,
            fn {url, _} = page_info ->
              fetch_orders_url(page_info, Map.get(etags, url))
            end,
            max_concurrency: max_concurrency,
            timeout: @work_interval
          )

        results = Enum.to_list(stream_results)

        updated_etags =
          results
          |> Enum.reduce(etags, fn
            {:ok, {url, new_etag}}, acc -> Map.put(acc, url, new_etag)
            {:ok, {:not_modified, url, new_etag}}, acc -> Map.put(acc, url, new_etag)
            {:error, {url, _reason}}, acc -> acc
            # Handle Task errors
            {_other, _}, acc -> acc
          end)

        {%{state | etags: updated_etags}, results}

      {:error, reason} ->
        IO.puts("Failed to fetch regions: #{inspect(reason)}")
        {state, []}
    end
  end

  defp fetch_regions do
    case Req.get(@regions_url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      other ->
        {:error, other}
    end
  end

  defp process_first_page(orders, url, etag) do
    if orders && length(orders) > 0 do
      upsert_orders(orders, url, etag || "")
      {:ok, etag}
    else
      :ok
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

  defp fetch_first_page(region_id) do
    Req.get(page_url(region_id, 1), params: [order_type: "all"])
  end

  defp page_url(region_id, page) do
    "#{@orders_base_url}/#{region_id}/orders/?order_type=all&page=#{page}"
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
        upsert_orders(body, url, new_etag)
        {:ok, url, new_etag}

      other ->
        IO.inspect(other, label: "Fetch #{url} failed")
        {:error, url, other}
    end
  end

  ## DATABASE ETAG SYNC

  defp load_etags_from_db do
    case Marketmailer.Database.all(Etag) do
      {:ok, etag_records} ->
        etag_records
        |> Enum.into(%{}, fn record ->
          {record.url, record.etag}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp save_etags_to_db(etags) do
    etag_list =
      Map.to_list(etags)
      |> Enum.map(fn {url, etag} ->
        [url: url, etag: etag]
      end)

    # Upsert etags (delete old, insert new)
    Marketmailer.Database.delete_all(Etag)
    Marketmailer.Database.insert_all(Etag, etag_list)
  end

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

        # Add etag_url and etag_value to keep orders in sync with their source
        Map.put(order_map, :etag_url, url)
        Map.put(order_map, :etag_value, etag)
      end)

    # Upsert: delete orders from this URL first, then insert fresh
    Marketmailer.Database.delete_by(Market, etag_url: url)

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
