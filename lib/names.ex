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

defmodule ESI.Ids do
	@moduledoc """
	Targeted EVE name -> id lookup via ESI's universe/ids endpoint.
	Used when the lazy id -> name backfill cannot cover a query string
	(e.g. PLEX missing from a cold names cache and sitting outside the
	bounded bulk-backfill window): one small POST discovers the type id
	directly. Only inventory_types are cached; characters, corporations
	and other categories are ignored.
	"""

	@url "https://esi.evetech.net/v3/universe/ids/"

	def resolve_inventory_type(name) when is_binary(name) do
		case resolve([name]) do
			[%{id: _, name: _} | _] = entries -> entries
			_ -> []
		end
	end

	def resolve(names) when is_list(names) do
		names =
			names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

		case names do
			[] -> []
			_ -> fetch(names)
		end
	end

	defp fetch(names) do
		ESI.acquire(@url)

		case Req.post(@url, json: names) do
			{:ok, %{status: 200, body: body} = response} when is_map(body) ->
				ESI.release(response.headers, @url)

				body
				|> Map.get("inventory_types", [])
				|> Enum.map(fn entry -> %{id: entry["id"], name: entry["name"]} end)

			{:ok, %{status: status} = response} ->
				ESI.release(response.headers, @url)
				Marketmailer.Log.warning("ids_resolve_error", %{status: status}, "ESI.Ids #{status}")

				[]

			{:error, error} ->
				Marketmailer.Log.error("ids_http_error", %{error: inspect(error)}, "ESI.Ids HTTP error: #{inspect(error)}")

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
	import Ecto.Query

	# Local cache read only - never blocks on HTTP, so embed rendering and
	# the 100ms broadcaster test windows stay fast. Names are seeded at boot
	# (see seed_region_names/1) and refreshed by the usual lazy backfills.
	def get_name(id) when is_integer(id) do
		Database.one(from name in "names", where: name.id == ^id, select: name.name)
	rescue
		_ -> nil
	catch
		_, _ -> nil
	end

	def get_name(_), do: nil

	# Bulk-resolves any uncached ids from a known set (e.g. all polled
	# regions) into the names cache. Safe to fire-and-forget at boot.
	def seed_region_names(ids) when is_list(ids) do
		ids = ids |> Enum.filter(&is_integer/1) |> Enum.uniq()

		cached =
			try do
				Database.all(from name in "names", where: name.id in ^ids, select: name.id)
			rescue
				_ -> []
			end

		missing = ids -- cached

		case ESI.Names.resolve(missing) do
			[] -> :ok
			entries -> upsert_names(entries)
		end
	rescue
		_ -> :ok
	catch
		_, _ -> :ok
	end

	# Fills the `names` cache for every type with cached market rows. Runs
	# once per boot in the background (see Application.start/2): bounded per
	# boot so a cold cache warms over a few restarts instead of stalling one
	# behind ~36 ESI chunks. Keeps single-item lookups a pure DB query.
	@seed_type_names_per_boot 5_000

	def seed_missing_type_names(limit \\ @seed_type_names_per_boot) do
		missing =
			try do
				Database.all(
					from market in "market",
						left_join: name in "names",
						on: name.id == market.type_id,
						where: is_nil(name.id),
						select: market.type_id,
						distinct: true,
						order_by: market.type_id,
						limit: ^limit
				)
			rescue
				_ -> []
			end

		case ESI.Names.resolve(missing) do
			[] -> :ok
			entries -> upsert_names(entries)
		end
	rescue
		_ -> :ok
	catch
		_, _ -> :ok
	end

	def upsert_names([]), do: :ok

	def upsert_names(entries),
		do:
			Market.DbWriter.write(fn ->
				Database.insert_all("names", entries, on_conflict: {:replace, [:name]}, conflict_target: :id)
			end)

	def upsert_system(entry),
		do:
			Market.DbWriter.write(fn ->
				Database.insert_all("systems", [entry],
					on_conflict: {:replace, [:name, :security_status, :region_name]},
					conflict_target: :system_id
				)
			end)
end
