defmodule ESI.Names do
	@moduledoc """
	Lazy EVE name cache backing store. Resolves any mix of type/system/location
	ids through ESI's bulk universe/names endpoint.
	"""

	@url "https://esi.evetech.net/v2/universe/names/"

	def resolve(ids) do
		ids
		|> Enum.uniq()
		|> Enum.reject(&is_nil/1)
		|> Enum.chunk_every(500)
		|> Enum.flat_map(&fetch_chunk/1)
	end

	defp fetch_chunk(chunk) do
		ESI.acquire(@url)

		case Req.post(@url, json: chunk) do
			{:ok, %{status: 200, body: body} = response} when is_list(body) ->
				ESI.release(response.headers, @url)
				Enum.map(body, fn entry -> %{id: entry["id"], name: entry["name"]} end)

			{:ok, %{status: status} = response} ->
				ESI.release(response.headers, @url)
				Marketmailer.Log.warning("names_resolve_error", %{status: status}, "ESI.Names #{status}")

				[]

			{:error, error} ->
				Marketmailer.Log.error("names_http_error", %{error: inspect(error)}, "ESI.Names HTTP error: #{inspect(error)}")

				[]
		end
	end
end

defmodule ESI.SystemInfo do
	@moduledoc """
	Resolves solar system metadata (name, security status, region name) lazily
	via the system -> constellation -> region chain.
	"""

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
		url = @base <> path
		ESI.acquire(url)

		case Req.get(url) do
			{:ok, %{status: 200, body: body} = response} ->
				ESI.release(response.headers, url)
				{:ok, body}

			{:ok, %{status: status} = response} ->
				ESI.release(response.headers, url)

				Marketmailer.Log.warning(
					"system_info_status",
					%{status: status, path: path},
					"ESI.SystemInfo #{status} #{path}"
				)

				{:error, status}

			{:error, error} ->
				Marketmailer.Log.error(
					"system_info_http_error",
					%{path: path, error: inspect(error)},
					"ESI.SystemInfo HTTP error #{path}: #{inspect(error)}"
				)

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
