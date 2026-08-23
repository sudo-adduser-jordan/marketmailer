defmodule ESI.Names do
	@moduledoc """
	Lazy EVE name cache backing store. Resolves any mix of type/system/location
	ids through ESI's bulk universe/names endpoint.
	"""

	require Logger

	@url "https://esi.evetech.net/v2/universe/names/"

	def resolve(ids) do
		ids
		|> Enum.uniq()
		|> Enum.reject(&is_nil/1)
		|> Enum.chunk_every(500)
		|> Enum.flat_map(&fetch_chunk/1)
	end

	defp fetch_chunk(chunk) do
		case Req.post(@url, json: chunk) do
			{:ok, %{status: 200, body: body}} when is_list(body) ->
				Enum.map(body, fn entry -> %{id: entry["id"], name: entry["name"]} end)

			{:ok, %{status: status}} ->
				Logger.warning("ESI.Names #{status}")
				[]

			{:error, error} ->
				Logger.error("ESI.Names HTTP error: #{inspect(error)}")
				[]
		end
	end
end

defmodule ESI.SystemInfo do
	@moduledoc """
	Resolves solar system metadata (name, security status, region name) lazily
	via the system -> constellation -> region chain.
	"""

	require Logger

	@base "https://esi.evetech.net"

	def fetch(system_id) do
		with {:ok, system} <- get("/v4/universe/systems/#{system_id}/"),
				 {:ok, constellation} <- get("/v1/universe/constellations/#{system["constellation_id"]}/"),
				 {:ok, region} <- get("/v1/universe/regions/#{constellation["region_id"]}/") do
			{:ok,
			 %{
				 system_id: system_id,
				 name: system["name"],
				 security_status: system["security_status"],
				 region_name: region["name"]
			 }}
		end
	end

	defp get(path) do
		case Req.get(@base <> path) do
			{:ok, %{status: 200, body: body}} ->
				{:ok, body}

			{:ok, %{status: status}} ->
				Logger.warning("ESI.SystemInfo #{status} #{path}")
				{:error, status}

			{:error, error} ->
				Logger.error("ESI.SystemInfo HTTP error #{path}: #{inspect(error)}")
				{:error, error}
		end
	end
end

defmodule Universe.Database do
	def upsert_names([]), do: :ok

	def upsert_names(entries),
		do: Database.insert_all("names", entries, on_conflict: {:replace, [:name]}, conflict_target: :id)

	def upsert_system(entry),
		do:
			Database.insert_all("systems", [entry],
				on_conflict: {:replace, [:name, :security_status, :region_name]},
				conflict_target: :system_id
			)
end
