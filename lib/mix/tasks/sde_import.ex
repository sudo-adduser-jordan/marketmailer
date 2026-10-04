defmodule Mix.Tasks.Sde.Import do
	@shortdoc "Import EVE names/systems from the official JSONL SDE"

	# Bulk-seeds the EVE name/system caches from the official JSONL SDE.
	#
	# Usage: mix sde.import [BUILD]
	#
	# Downloads eve-online-static-data-<build>-jsonl.zip (resolving "latest"
	# via tranquility/latest.jsonl when no build is given), extracts only the
	# datasets backing our caches, and streams each JSONL file line-by-line
	# into the write-database caches through the single-writer path. The
	# write -> read sync then carries the rows to the read database like any
	# other cache fill. No per-request ESI backfill is needed for SDE-covered
	# ids; the ticker stays as the fallback for the rest.
	use Mix.Task

	@latest_url "https://developers.eveonline.com/static-data/tranquility/latest.jsonl"
	@zip_url_template "https://developers.eveonline.com/static-data/tranquility/eve-online-static-data-BUILD-jsonl.zip"

	# Zip entry basenames backing our caches. npcStations.jsonl is
	# intentionally absent: official station entries carry no name field
	# (names compose from operations + celestials), so station names keep
	# warming through the fast bulk ESI ticker instead.
	@needed_files [
		"types.jsonl",
		"mapSolarSystems.jsonl",
		"mapConstellations.jsonl",
		"mapRegions.jsonl"
	]

	@impl true
	def run(args) do
		# Repos need the Ecto supervision tree (repo registry); the full
		# application (pollers, bot, dashboard) must NOT boot for an import.
		{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

		# Req performs HTTP through a named Finch pool, started on demand.
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

		# Constellation/region maps join in memory (hundreds of rows) so
		# systems resolve to region names in one streaming pass.
		regions = load_keyed_map(paths["mapRegions.jsonl"], ["name"])
		constellations = load_keyed_map(paths["mapConstellations.jsonl"], ["regionID", "region_id"], regions)

		import_types(paths["types.jsonl"])
		import_systems(paths["mapSolarSystems.jsonl"], constellations)
		Mix.shell().info("station names: skipped (no names in official npcStations.jsonl; ESI ticker covers them)")
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

	# Extracts only the datasets we consume; returns %{basename => path}.
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

				# Unzip preserves the in-archive path; flatten to dir root.
				extracted = Path.join(dir, to_string(name))
				if extracted != out, do: File.rename!(extracted, out)
			end

			{base, out}
		end)
	end

	# Loads a small reference file into %{key => string}, following one id
	# link through an already-loaded map (constellation -> region name).
	# Tries each candidate field in order; localized objects resolve via
	# their English entry.
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

	defp load_keyed_map(path, field, link), do: load_keyed_map(path, [field], link)

	defp follow_link(nil, _), do: nil
	defp follow_link(id, link) when is_map(link) and is_integer(id), do: Map.get(link, id)
	defp follow_link(value, _), do: as_text(value)

	defp as_text(nil), do: nil
	defp as_text(value) when is_binary(value), do: value
	defp as_text(%{"en" => name}) when is_binary(name), do: name
	defp as_text(_), do: nil

	# Bulk writes against the live poller DB contend on SQLite's single
	# write lock ("database is locked" fails fast, no busy wait). Retry
	# with backoff so a background import always drains; raises after the
	# budget so failures are loud, never silently swallowed.
	@write_attempts 60
	@write_delay_ms 500

	defp with_write_retry(fun, attempts \\ @write_attempts)
	defp with_write_retry(_fun, 0), do: Mix.raise("SDE import write failed: lock budget exhausted")

	defp with_write_retry(fun, attempts) do
		case fun.() do
			{:error, reason} ->
				if lock_contention_value?(reason) and attempts > 1 do
					Process.sleep(@write_delay_ms)
					with_write_retry(fun, attempts - 1)
				else
					Mix.raise("SDE import write failed: #{inspect(reason)}")
				end

			_ ->
				:ok
		end
	rescue
		e ->
			if lock_contention?(e) and attempts > 1 do
				Process.sleep(@write_delay_ms)
				with_write_retry(fun, attempts - 1)
			else
				reraise e, __STACKTRACE__
			end
	end

	defp lock_contention_value?(%Exqlite.Error{} = e), do: lock_contention?(e)
	defp lock_contention_value?(%DBConnection.ConnectionError{}), do: true

	defp lock_contention_value?(reason) when is_binary(reason),
		do: String.contains?(reason, ["database is locked", "Database busy"])

	defp lock_contention_value?(_), do: false

	defp lock_contention?(%Exqlite.Error{} = e),
		do: String.contains?(Exception.message(e), ["database is locked", "Database busy"])

	defp lock_contention?(%DBConnection.ConnectionError{}), do: true
	defp lock_contention?(_), do: false

	# Direct repo writes with task-owned retry. Universe.Database wraps
	# everything in DbWriter, which converts a spent lock budget into an
	# {:error, ...} return — invisible to a bulk importer counting chunks.
	# Same conflict semantics, same chunk discipline, but failures are loud.
	defp insert_names(chunk) do
		with_write_retry(fn ->
			Database.insert_all("names", chunk, on_conflict: {:replace, [:name]}, conflict_target: :id)
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

	defp import_types(path) do
		{count, ids} =
			stream_entries(path)
			|> Stream.map(fn
				%{"_key" => id, "name" => %{"en" => name}, "published" => true}
				when is_integer(id) and is_binary(name) ->
					%{id: id, name: name}

				_ ->
					nil
			end)
			|> Stream.reject(&is_nil/1)
			|> Enum.chunk_every(500)
			|> Enum.reduce({0, []}, fn chunk, {acc, ids} ->
				insert_names(chunk)
				{acc + length(chunk), [Enum.map(chunk, & &1.id) | ids]}
			end)

		ids = List.flatten(ids)
		verify_present!("names", "id", ids)
		Mix.shell().info("imported #{count} published type names (verified #{length(ids)} present)")
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

	# Reads back every imported id in chunks; raises unless all are present.
	# Closes the silent-partial-write hole for good.
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
		Market.DbWriter.write(fn ->
			Database.query!("CREATE TABLE IF NOT EXISTS sde_imports (build TEXT PRIMARY KEY, imported_at TEXT NOT NULL)", [])

			Database.query!(
				"INSERT INTO sde_imports (build, imported_at) VALUES (?, ?) ON CONFLICT(build) DO UPDATE SET imported_at = excluded.imported_at",
				[
					to_string(build),
					NaiveDateTime.utc_now(:second) |> NaiveDateTime.to_string()
				]
			)
		end)
	end
end
