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


# defmodule EtagCache do
#   use Agent

#   def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

#   def get(region_id), do: Agent.get(__MODULE__, &Map.get(&1, region_id))
#   def put(region_id, etag), do: Agent.update(__MODULE__, &Map.put(&1, region_id, etag))
# end
