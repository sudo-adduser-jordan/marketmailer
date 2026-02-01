defmodule EtagCache do
  @table_name :request_etags

  # Initialize ETS table (call this once during app startup)
  def start_link do
    :ets.new(@table_name, [:named_table, :set, :public])
    :ok
  end

  # Store ETag for a request
  def store_etag(request, etag) do
    :ets.insert(@table_name, {request, etag})
  end

  # Retrieve ETag for a request
  def get_etag(request) do
    case :ets.lookup(@table_name, request) do
      [{^request, etag}] -> etag
      [] -> nil
    end
  end

end
