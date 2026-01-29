# defmodule EsiMarketFetcher do
#   @ets_table :request_etags

#   # Call this once during application startup
#   def init do
#     unless :ets.whereis(@ets_table) != :undefined do
#       :ets.new(@ets_table, [:named_table, :set, :public])
#     end
#     :ok
#   end

#   def fetch_regions do
#     Req.get!("https://esi.evetech.net/v1/universe/regions").body
#   end

#   def fetch_region_orders_paginated(region_id) do
#     etag = get_etag(region_id)
#     headers = if etag, do: [{"if_none_match", etag}], else: []

#     url = "/markets/regions/#{region_id}/orders"

#     # Create the stream
#     stream = EsiEveOnline.stream!(url, headers)

#     # Fetch all pages, stop early if 304 (not modified)
#     case fetch_pages(stream, region_id, etag, []) do
#       {:ok, data_pages, _} ->
#         total_orders = List.flatten(data_pages)
#         IO.puts("Region #{region_id} total orders: #{length(total_orders)}")
#         {:ok, total_orders}
#       {:error, reason} ->
#         IO.puts("Error in pagination for region #{region_id}: #{inspect(reason)}")
#         {:error, reason}
#     end
#   end

#   defp fetch_pages(stream, region_id, etag, acc) do
#     Enum.reduce_while(stream, {:ok, acc, etag}, fn
#       {:ok, data, headers}, {:ok, acc, current_etag} ->
#         # Update ETag
#         new_etag = case List.keyfind(headers, "etag", 0) do
#             {_, value} -> value
#             nil -> current_etag
#         end
#         store_etag(region_id, new_etag)
#         {:cont, {:ok, [data | acc], new_etag}}

#       {:error, %Esi.Error{status: 304}}, {:ok, acc, current_etag} ->
#         # Data not modified; stop fetching further pages
#         {:halt, {:ok, Enum.reverse(acc), current_etag}}

#       {:error, reason}, _ ->
#         {:halt, {:error, reason}}
#     end)
#   end

#   def fetch_all do
#     init()
#     regions = fetch_regions()

#     results =
#       Enum.map(regions, fn region_id ->
#         case fetch_region_orders_paginated(region_id) do
#           {:ok, data_pages} ->
#             total_orders = List.flatten(data_pages)
#             IO.puts("Region #{region_id} total orders: #{length(total_orders)}")
#             {region_id, total_orders}

#           {:error, reason} ->
#             IO.puts("Error fetching region #{region_id}: #{inspect(reason)}")
#             {region_id, :error}
#         end
#       end)

#     IO.inspect(results, label: "Market Orders with Pagination & ETag")
#     results
#   end
# end
