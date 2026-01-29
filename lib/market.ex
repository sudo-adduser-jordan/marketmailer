defmodule EsiMarketFetcher do
  @moduledoc """
  Fetches market orders from all regions with ETag caching using ETS.
  """

  @ets_table :region_etags

  # Call this once during application startup
  def init do
    # Create ETS table if it doesn't exist
    unless :ets.whereis(@ets_table) != :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public])
    end
    :ok
  end

  # Store ETag for a region
  def store_etag(region_id, etag) do
    :ets.insert(@ets_table, {region_id, etag})
  end

  # Retrieve ETag for a region
  def get_etag(region_id) do
    case :ets.lookup(@ets_table, region_id) do
      [{^region_id, etag}] -> etag
      [] -> nil
    end
  end

  # Fetch all regions
  def fetch_regions do
    Req.get!("https://esi.evetech.net/v1/universe/regions").body
  end

  # Fetch market orders for a region with ETag support
  def fetch_region_orders(region_id) do
    etag = get_etag(region_id)

    headers =
      if etag do
        [{"if_none_match", etag}]
      else
        []
      end

    url = "/markets/regions/#{region_id}/orders"

    case EsiEveOnline.request_with_headers(url, headers) do
      {:ok, data, response_headers} ->
        # Extract new ETag
        new_etag =
          case List.keyfind(response_headers, "etag", 0) do
            {_, value} -> value
            nil -> etag
          end

        # Store new ETag
        store_etag(region_id, new_etag)
        {:ok, data}

      {:error, %Esi.Error{status: 304}} ->
        # Not modified
        {:not_modified}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run the full process
  def run do
    init()
    regions = fetch_regions()

    results =
      Enum.map(regions, fn region_id ->
        case fetch_region_orders(region_id) do
          {:ok, data} ->
            IO.puts("Fetched data for region #{region_id}, orders count: #{length(data)}")
            {region_id, data}

          {:not_modified} ->
            IO.puts("Region #{region_id} data not modified.")
            {region_id, :not_modified}

          {:error, reason} ->
            IO.puts("Error fetching region #{region_id}: #{inspect(reason)}")
            {region_id, :error}
        end
      end)

    IO.inspect(results, label: "Market Orders Results")
    results
  end
end
