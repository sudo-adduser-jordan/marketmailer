defmodule EsiEtagCache do
  @table_name :region_etags

  # Initialize ETS table (call this once during app startup)
  def start_link do
    :ets.new(@table_name, [:named_table, :set, :public])
    :ok
  end

  # Store ETag for a region
  def store_etag(region_id, etag) do
    :ets.insert(@table_name, {region_id, etag})
  end

  # # Function to store ETag for a region
# def store_etag(region_id, etag) do
#   :ets.insert(:region_etags, {region_id, etag})
# end


  # Retrieve ETag for a region
  def get_etag(region_id) do
    case :ets.lookup(@table_name, region_id) do
      [{^region_id, etag}] -> etag
      [] -> nil
    end
  end

# # Function to retrieve ETag for a region
# def get_etag(region_id) do
#   case :ets.lookup(:region_etags, region_id) do
#     [{^region_id, etag}] -> etag
#     [] -> nil
#   end
# end

end
