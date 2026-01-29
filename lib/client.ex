defmodule Marketmailer.Client do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    work()
    schedule_work()
    {:ok, state}
  end

  def handle_info(:work, state) do
    work()
    schedule_work()
    {:noreply, state}
  end

  defp schedule_work do
    Process.send_after(self(), :work, 300_000) # 5 minutes
  end

  defp work() do
    regions = Req.get!("https://esi.evetech.net/v1/universe/regions").body |> IO.inspect()

    Marketmailer.Database.delete_all(Market)

    Task.async_stream(
      regions,
      fn region ->
        IO.inspect(region)



        etag = "sfasdfasdfsfs"
        headers = [{"If-None-Match", etag}]
        case Esi.Api.Markets.orders(region, order_type: "all", headers: headers) do
          {:ok, response_data, response_headers} ->
            # Extract new ETag from response headers if available
            new_etag =
              case List.keyfind(response_headers, "etag", 0) do
                {_, value} -> value
                nil -> etag
              end

            # Process your orders
            orders = Enum.to_list(response_data)
            # Save new_etag for next request
            IO.puts("Fetched orders with ETag: #{new_etag}")
            {orders, new_etag}

          {:error, %Esi.Error{status: 304}} ->
            IO.puts("Data not modified since last fetch.")
            :not_modified

          {:error, reason} ->
            IO.puts("Error fetching data: #{inspect(reason)}")
            {:error, reason}
        end
        # rows =
        #   Enum.map(orders, fn order ->
        #     [
        #       {:duration, order["duration"]},
        #       {:is_buy_order, order["is_buy_order"]},
        #       {:issued, order["issued"]},
        #       {:location_id, order["location_id"]},
        #       {:min_volume, order["min_volume"]},
        #       {:order_id, order["order_id"]},
        #       {:price, order["price"]},
        #       {:range, order["range"]},
        #       {:system_id, order["system_id"]},
        #       {:type_id, order["type_id"]},
        #       {:volume_remain, order["volume_remain"]},
        #       {:volume_total, order["volume_total"]}
        #     ]
        #   end)

        # Enum.chunk_every(rows, 2048)
        # |> Enum.each(fn chunk ->
        #   Marketmailer.Database.insert_all(Market, chunk)
        # end)

        IO.puts("#{region} complete")
      end,
      timeout: 300_000
    )
    |> Enum.to_list()

    IO.puts("work completed.")
  end
end


# case EsiEveOnline.request_with_headers("/characters/1234567890", headers) do
#   {:ok, data, response_headers} ->
#     # Save the new ETag if provided
#     new_etag = List.keyfind(response_headers, "etag", 0) |> elem(1)
#     # Store new_etag for future requests
#   {:error, %Esi.Error{status: 304}} ->
#     # Data has not changed
#   {:error, reason} ->
#     # Handle error
# end

# def fetch_market_orders_with_etag(region_id, stored_etag \\ nil) do
#   headers = case stored_etag do
#       nil -> []
#       etag -> [{"if_none_match", etag}]
#     end

#   case EsiEveOnline.request_with_headers("/markets/regions/#{region_id}/orders", headers) do
#     {:ok, orders, response_headers} ->
#       # Extract new ETag from response headers
#       new_etag = case List.keyfind(response_headers, "etag", 0) do
#           {_, etag_value} -> etag_value
#           nil -> nil
#         end

#       IO.puts("Fetched market orders. ETag: #{new_etag}")
#       {orders, new_etag}

#     {:error, %Esi.Error{status: 304}} ->
#       # Data not modified, no need to process
#       IO.puts("Market orders not modified since last fetch.")
#       {:not_modified, stored_etag}

#     {:error, reason} ->
#       IO.puts("Error fetching market orders: #{reason}")
#       {:error, reason}
#   end
# end




# # Step 1: Fetch regions
# regions = Req.get!("https://esi.evetech.net/v1/universe/regions").body
# |> IO.inspect()

# # Initialize a map to store ETags for each region
# # In a real application, you'd persist this between requests
# etags = %{}

# # Helper function to fetch market orders with ETag support
# def fetch_market_orders(region_id, etags) do
#   url = "/markets/regions/#{region_id}/orders"

#   # Get the stored ETag for this region, if any
#   etag = Map.get(etags, region_id)

#   # Prepare headers
#   headers = if etag do
#     [{"if_none_match", etag}]
#   else
#     []
#   end

#   # Make the request
#   case EsiEveOnline.request_with_headers(url, headers) do
#     {:ok, data, response_headers} ->
#       # Extract new ETag from response headers
#       new_etag = List.keyfind(response_headers, "etag", 0) |> case do
#         nil -> etag
#         {_, value} -> value
#       end

#       # Return data and updated etags map
#       {data, Map.put(etags, region_id, new_etag)}

#     {:error, %Esi.Error{status: 304}} ->
#       # Data not modified
#       {:not_modified, etags}

#     {:error, reason} ->
#       IO.puts("Error fetching region #{region_id}: #{reason}")
#       {:error, etags}
#   end
# end

# # Step 2: Loop through regions and fetch market orders with ETag support
# result = Enum.reduce(regions, {%{}, etags}, fn region_id, {acc, etags_map} ->
#   case fetch_market_orders(region_id, etags_map) do
#     {{:not_modified, new_etags}} ->
#       # Data hasn't changed; skip
#       {acc, new_etags}
#     {{:ok, data}, new_etags} ->
#       # Store data with region id
#       {Map.put(acc, region_id, data), new_etags}
#     {:error, new_etags} ->
#       {acc, new_etags}
#   end
# end)

# # Now, `result` is a map of region_id to market orders, with ETags managed
# IO.inspect(result)


# Store ETags per page/request URL
etags = %{}

def fetch_page_with_etag(page_url, current_etag) do
  headers =
    if current_etag do
      [{"If-None-Match", current_etag}]
    else
      []
    end

  case Esi.Api.Markets.orders(page_url, headers: headers) do
    {:ok, response_data, response_headers} ->
      new_etag =
        case List.keyfind(response_headers, "etag", 0) do
          {_, value} -> value
          nil -> current_etag
        end
      orders = Enum.to_list(response_data)
      {:ok, orders, new_etag}

    {:error, %Esi.Error{status: 304}} ->
      # No change
      {:not_modified, current_etag}

    {:error, reason} ->
      {:error, reason}
  end
end



# For each page/request URL
page_url = "/some/request/url"
current_etag = Map.get(etags, page_url)

case fetch_page_with_etag(page_url, current_etag) do
  {:ok, data, new_etag} ->
    # Save the new ETag for this page
    etags = Map.put(etags, page_url, new_etag)
    # Process data
  {:not_modified, _} ->
    # Data unchanged
  {:error, reason} ->
    # Handle error
end
