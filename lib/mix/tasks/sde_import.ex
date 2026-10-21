defmodule Mix.Tasks.Sde.Import do
	use Mix.Task

	@latest_url "https://developers.eveonline.com/static-data/tranquility/latest.jsonl"
	@zip_url_template "https://developers.eveonline.com/static-data/tranquility/eve-online-static-data-BUILD-jsonl.zip"

	@needed_files [
		"types.jsonl",
		"mapSolarSystems.jsonl",
		"mapConstellations.jsonl",
		"mapRegions.jsonl",
		"npcStations.jsonl",
		"stationOperations.jsonl",
		"npcCorporations.jsonl",
		"mapPlanets.jsonl",
		"mapMoons.jsonl",
		"mapStars.jsonl"
	]

	# Capital hulls that cannot enter high sec. Their Jita buy orders can never be
	# filled there, so every Jita buy-wall query filters these types out through
	# names.is_capital_ship. Freighters (513) and jump freighters (902) can gate
	# into Jita and stay in the list, as do capital modules and components.
	@capital_ship_groups [30, 485, 547, 659, 883, 1538, 4594, 5120]

	@impl true
	def run(args) do
		{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

		{:ok, _} = Application.ensure_all_started(:req)

		case Finch.start_link(name: Req.Finch) do
			{:ok, _} -> :ok
			{:error, {:already_started, _}} -> :ok
		end

		{:ok, _} = Database.start_link()

		Ecto.Migrator.run(
			Database,
			Path.join(:code.priv_dir(:marketmailer), "repo/migrations"),
			:up,
			all: true
		)

		build = resolve_build(args)
		dir = sde_dir(build)
		File.mkdir_p!(dir)

		zip_path = Path.join(dir, "eve-online-static-data-#{build}-jsonl.zip")
		download_once(zip_path, build)
		paths = extract_needed(zip_path, dir)

		regions = load_keyed_map(paths["mapRegions.jsonl"], ["name"])
		constellations = load_keyed_map(paths["mapConstellations.jsonl"], ["regionID", "region_id"], regions)

		import_regions(regions)
		import_types(paths["types.jsonl"])
		import_systems(paths["mapSolarSystems.jsonl"], constellations)
		import_stations(paths)
		record_build(build)

		Mix.shell().info("SDE import done (build #{build})")
	end

	def sde_dir(build), do: Path.join(["priv", "data", "sde", to_string(build)])

	def resolve_build([build | _]), do: String.trim(build)

	def resolve_build([]) do
		case Req.get(@latest_url) do
			{:ok, %{status: 200, body: %{"buildNumber" => build}}} -> to_string(build)
			{:ok, %{status: 200, body: body}} when is_binary(body) -> parse_latest_jsonl(body)
			other -> Mix.raise("could not resolve latest SDE build: #{inspect(other)}")
		end
	end

	defp parse_latest_jsonl(body) do
		body
		|> String.split("\n", trim: true)
		|> Enum.find_value(fn line ->
			case Jason.decode(line) do
				{:ok, %{"buildNumber" => build}} -> to_string(build)
				_ -> nil
			end
		end) ||
			Mix.raise("could not parse latest.jsonl for buildNumber")
	end

	defp download_once(path, build) do
		if File.exists?(path) do
			Mix.shell().info("SDE zip already present: #{path}")
		else
			url = String.replace(@zip_url_template, "BUILD", to_string(build))

			Mix.shell().info("downloading #{url}")

			case Req.get(url, into: File.stream!(path), redirect: true) do
				{:ok, %{status: 200}} -> :ok
				other -> Mix.raise("SDE download failed: #{inspect(other)}")
			end
		end
	end

	defp extract_needed(zip_path, dir) do
		entries =
			case :zip.list_dir(String.to_charlist(zip_path)) do
				{:ok, list} ->
					for {:zip_file, name, _, _, _, _} <- list,
							base = Path.basename(to_string(name)),
							base in @needed_files,
							do: {base, name}

				{:error, reason} ->
					Mix.raise("could not list SDE zip: #{inspect(reason)}")
			end

		missing = @needed_files -- Enum.map(entries, &elem(&1, 0))

		if missing != [] do
			Mix.raise("SDE zip is missing datasets: #{Enum.join(missing, ", ")}")
		end

		Map.new(entries, fn {base, name} ->
			out = Path.join(dir, base)

			if !File.exists?(out) do
				case :zip.unzip(String.to_charlist(zip_path), [{:file_list, [name]}, {:cwd, String.to_charlist(dir)}]) do
					{:ok, _} -> :ok
					{:error, reason} -> Mix.raise("could not extract #{base}: #{inspect(reason)}")
				end

				extracted = Path.join(dir, to_string(name))
				if extracted != out, do: File.rename!(extracted, out)
			end

			{base, out}
		end)
	end

	defp load_keyed_map(path, fields, link \\ nil)

	defp load_keyed_map(path, fields, link) when is_list(fields) do
		path
		|> File.stream!()
		|> Stream.map(&String.trim_trailing(&1, "\n"))
		|> Stream.reject(&(&1 == ""))
		|> Enum.reduce(%{}, fn line, acc ->
			case Jason.decode(line) do
				{:ok, %{"_key" => key} = entry} ->
					raw = Enum.find_value(fields, fn field -> entry[field] end)

					case follow_link(raw, link) do
						nil -> acc
						value -> Map.put(acc, key, value)
					end

				_ ->
					acc
			end
		end)
	end

	defp follow_link(nil, _), do: nil
	defp follow_link(id, link) when is_map(link) and is_integer(id), do: Map.get(link, id)
	defp follow_link(value, _), do: as_text(value)

	defp as_text(nil), do: nil
	defp as_text(value) when is_binary(value), do: value
	defp as_text(%{"en" => name}) when is_binary(name), do: name
	defp as_text(_), do: nil

	@write_attempts 60
	@write_delay_ms 500

	defp with_write_retry(fun, attempts \\ @write_attempts)
	defp with_write_retry(_fun, 0), do: Mix.raise("SDE import write failed: lock budget exhausted")

	defp with_write_retry(fun, attempts) do
		_fun_result = fun.()
		:ok
	rescue
		e ->
			if lock_contention?(e) and attempts > 1 do
				Process.sleep(@write_delay_ms)
				with_write_retry(fun, attempts - 1)
			else
				reraise e, __STACKTRACE__
			end
	end

	defp lock_contention?(%Exqlite.Error{} = e),
		do: String.contains?(Exception.message(e), ["database is locked", "Database busy"])

	defp lock_contention?(%DBConnection.ConnectionError{}), do: true
	defp lock_contention?(_), do: false

	defp insert_names(chunk) do
		with_write_retry(fn ->
			Database.insert_all("names", chunk,
				on_conflict: {:replace, [:name, :is_capital_ship]},
				conflict_target: :id
			)
		end)
	end

	defp insert_system(entry) do
		with_write_retry(fn ->
			Database.insert_all("systems", [entry],
				on_conflict: {:replace, [:name, :security_status, :region_name]},
				conflict_target: :system_id
			)
		end)
	end

	def capital_ship_group?(group_id), do: group_id in @capital_ship_groups

	# Pure mapping so the region seed can be tested without the SDE files.
	def region_rows(regions) do
		regions
		|> Enum.map(fn {id, name} -> %{region_id: id, name: name} end)
		|> Enum.sort_by(& &1.region_id)
	end

	# The table is authoritative, not additive: a region removed from the SDE
	# must stop being polled. One transaction keeps the cache from ever being
	# seen empty (which would boot the supervisor with no region managers).
	defp import_regions(regions) do
		rows = region_rows(regions)

		with_write_retry(fn ->
			{:ok, _} =
				Database.transaction(fn ->
					Database.delete_all("regions")

					rows
					|> Enum.chunk_every(500)
					|> Enum.each(&Database.insert_all("regions", &1))
				end)
		end)

		ids = Enum.map(rows, & &1.region_id)
		verify_present!("regions", "region_id", ids)
		Mix.shell().info("imported #{length(rows)} regions (verified #{length(ids)} present)")
	end

	defp import_types(path) do
		{count, capital_count, ids} =
			stream_entries(path)
			|> Stream.map(fn
				%{"_key" => id, "name" => %{"en" => name}, "published" => true} = entry
				when is_integer(id) and is_binary(name) ->
					%{
						id: id,
						name: name,
						is_capital_ship: if(capital_ship_group?(entry["groupID"]), do: 1, else: 0)
					}

				_ ->
					nil
			end)
			|> Stream.reject(&is_nil/1)
			|> Enum.chunk_every(500)
			|> Enum.reduce({0, 0, []}, fn chunk, {acc, capital, ids} ->
				insert_names(chunk)
				{acc + length(chunk), capital + Enum.count(chunk, &(&1.is_capital_ship == 1)), [Enum.map(chunk, & &1.id) | ids]}
			end)

		ids = List.flatten(ids)
		verify_present!("names", "id", ids)

		Mix.shell().info(
			"imported #{count} published type names (#{capital_count} capital hulls, verified #{length(ids)} present)"
		)
	end

	defp import_systems(path, constellations) do
		{count, ids} =
			stream_entries(path)
			|> Stream.map(fn
				%{"_key" => id} = entry when is_integer(id) ->
					%{
						system_id: id,
						name: as_text(entry["name"]) || to_string(id),
						security_status: entry["securityStatus"] || entry["security_status"],
						region_name: Map.get(constellations, entry["constellationID"] || entry["constellation_id"]) || "?"
					}

				_ ->
					nil
			end)
			|> Stream.reject(&is_nil/1)
			|> Enum.chunk_every(100)
			|> Enum.reduce({0, []}, fn chunk, {acc, ids} ->
				Enum.each(chunk, &insert_system/1)
				{acc + length(chunk), [Enum.map(chunk, & &1.system_id) | ids]}
			end)

		ids = List.flatten(ids)
		verify_present!("systems", "system_id", ids)
		Mix.shell().info("imported #{count} systems (verified #{length(ids)} present)")
	end

	defp import_stations(paths) do
		stations = paths["npcStations.jsonl"] |> stream_entries() |> Enum.to_list()
		orbit_ids = stations |> Enum.map(& &1["orbitID"]) |> Enum.uniq()

		moons =
			load_celestials(paths["mapMoons.jsonl"], orbit_ids, &%{planet_id: &1["orbitID"], index: &1["orbitIndex"]})

		planet_ids =
			((orbit_ids -- Map.keys(moons)) ++ Enum.map(moons, fn {_id, moon} -> moon.planet_id end))
			|> Enum.uniq()

		planets = load_celestials(paths["mapPlanets.jsonl"], planet_ids, &%{index: &1["celestialIndex"]})

		star_ids =
			paths["mapStars.jsonl"]
			|> stream_entries()
			|> Stream.map(& &1["_key"])
			|> Stream.filter(&is_integer/1)
			|> MapSet.new()

		lookups = %{
			systems: load_keyed_map(paths["mapSolarSystems.jsonl"], ["name"]),
			corps: load_keyed_map(paths["npcCorporations.jsonl"], ["name"]),
			ops: load_keyed_map(paths["stationOperations.jsonl"], ["operationName"]),
			planets: planets,
			moons: moons,
			stars: star_ids
		}

		{composed, failed} =
			stations
			|> Enum.map(&compose_station_name(&1, lookups))
			|> Enum.split_with(&match?(%{id: _, name: _}, &1))

		if failed != [] do
			ids = failed |> Enum.map(fn %{id: id} -> id end) |> Enum.take(5)
			Mix.raise("SDE station compose failed for #{length(failed)} stations (e.g. #{inspect(ids)})")
		end

		{count, ids} =
			composed
			|> Enum.map(&Map.put(&1, :is_capital_ship, 0))
			|> Enum.chunk_every(500)
			|> Enum.reduce({0, []}, fn chunk, {acc, ids} ->
				insert_names(chunk)
				{acc + length(chunk), [Enum.map(chunk, & &1.id) | ids]}
			end)

		ids = List.flatten(ids)
		verify_present!("names", "id", ids)
		Mix.shell().info("imported #{count} NPC station names (verified #{length(ids)} present)")
	end

	def compose_station_name(%{"_key" => id} = station, lookups) when is_integer(id) do
		with system_name when is_binary(system_name) <- Map.get(lookups.systems, station["solarSystemID"]),
				 {:ok, celestial} <- celestial_label(station, lookups),
				 owner when is_binary(owner) <- Map.get(lookups.corps, station["ownerID"]),
				 suffix when is_binary(suffix) <- station_suffix(station, owner, lookups.ops) do
			%{id: id, name: "#{celestial} - #{suffix}"}
		else
			_ -> nil
		end
	end

	def compose_station_name(_station, _lookups), do: nil

	defp celestial_label(%{"orbitID" => orbit_id, "solarSystemID" => system_id}, lookups) do
		system_name = Map.get(lookups.systems, system_id)

		cond do
			not is_binary(system_name) ->
				:error

			(match = Map.get(lookups.moons, orbit_id)) != nil ->
				with %{planet_id: planet_id, index: index} when is_integer(index) <- match,
						 %{index: planet_index} when is_integer(planet_index) <- Map.get(lookups.planets, planet_id) do
					{:ok, "#{system_name} #{roman(planet_index)} - Moon #{index}"}
				else
					_ -> :error
				end

			(match = Map.get(lookups.planets, orbit_id)) != nil ->
				case match do
					%{index: index} when is_integer(index) -> {:ok, "#{system_name} #{roman(index)}"}
					_ -> :error
				end

			MapSet.member?(lookups.stars, orbit_id) ->
				{:ok, system_name}

			true ->
				:error
		end
	end

	defp station_suffix(%{"useOperationName" => true, "operationID" => op_id}, owner, ops) do
		case Map.get(ops, op_id) do
			nil -> nil
			operation -> "#{owner} #{operation}"
		end
	end

	defp station_suffix(_station, owner, _ops), do: owner

	defp load_celestials(path, wanted, project) do
		wanted = MapSet.new(wanted)

		path
		|> stream_entries()
		|> Stream.filter(fn
			%{"_key" => id} when is_integer(id) -> MapSet.member?(wanted, id)
			_ -> false
		end)
		|> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, entry["_key"], project.(entry)) end)
	end

	@roman_pairs [
		{1000, "M"},
		{900, "CM"},
		{500, "D"},
		{400, "CD"},
		{100, "C"},
		{90, "XC"},
		{50, "L"},
		{40, "XL"},
		{10, "X"},
		{9, "IX"},
		{5, "V"},
		{4, "IV"},
		{1, "I"}
	]

	defp roman(n) when is_integer(n) and n > 0, do: roman(n, @roman_pairs)

	defp roman(0, _), do: ""
	defp roman(n, [{value, numeral} | _] = pairs) when n >= value, do: numeral <> roman(n - value, pairs)
	defp roman(n, [_ | rest]), do: roman(n, rest)

	defp verify_present!(table, column, ids) do
		missing =
			ids
			|> Enum.chunk_every(500)
			|> Enum.flat_map(fn chunk ->
				placeholders = Enum.map_join(chunk, ",", fn _ -> "?" end)

				%{rows: rows} = Database.query!("SELECT #{column} FROM #{table} WHERE #{column} IN (#{placeholders})", chunk)

				present = MapSet.new(rows, fn [id] -> id end)
				Enum.reject(chunk, &MapSet.member?(present, &1))
			end)

		if missing != [] do
			Mix.raise(
				"SDE import verify failed: #{length(missing)} #{table} rows missing (e.g. #{inspect(Enum.take(missing, 5))})"
			)
		end

		:ok
	end

	defp stream_entries(path) do
		path
		|> File.stream!()
		|> Stream.map(&String.trim_trailing(&1, "\n"))
		|> Stream.reject(&(&1 == ""))
		|> Stream.map(fn line ->
			case Jason.decode(line) do
				{:ok, entry} when is_map(entry) -> entry
				_ -> nil
			end
		end)
		|> Stream.reject(&is_nil/1)
	end

	defp record_build(build) do
		case Database.Writer.write(fn ->
					 Database.query!(
						 "CREATE TABLE IF NOT EXISTS sde_imports (build TEXT PRIMARY KEY, imported_at TEXT NOT NULL)",
						 []
					 )

					 Database.query!(
						 "INSERT INTO sde_imports (build, imported_at) VALUES (?, ?) ON CONFLICT(build) DO UPDATE SET imported_at = excluded.imported_at",
						 [
							 to_string(build),
							 NaiveDateTime.utc_now(:second) |> NaiveDateTime.to_string()
						 ]
					 )
				 end) do
			{:ok, _} -> :ok
			{:error, e} -> raise(e)
		end
	end
end
