defmodule Market.Sync do
	# One-way delta copy: write database -> read database. Runs after every
	# market sync cycle completes and before the broadcast renders, so
	# advertised data is always exactly what the read database holds.
	#
	# - `market` is delta-copied on an (updated_at, order_id) watermark
	#   (the write DB never deletes market rows, so upserts suffice).
	# - `names`/`systems` have no timestamps and stay small, so they are
	#   fully replaced each run.
	# - The read schema (tables + view + indexes) is ensured idempotently;
	#   the read database has no Ecto migrations, it is rebuilt not migrated.
	# - Never raises: errors log once and return {:error, reason} so the
	#   caller can skip the broadcast instead of sending stale-as-fresh data.

	# Chunk sized so one multi-row INSERT stays under SQLite's bound
	# parameter ceiling (14 columns x rows): 2000 rows ~= 28k params.
	@market_chunk_size 2000
	@cache_chunk_size 500
	@market_fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total inserted_at updated_at)a

	def run do
		started = System.monotonic_time(:millisecond)
		:ok = ensure_read_schema()
		{:ok, cache_counts} = copy_caches()
		market_count = copy_market_deltas()

		Marketmailer.Log.info(
			"read_sync_done",
			%{
				market_rows: market_count,
				cache_rows: cache_counts,
				elapsed_ms: System.monotonic_time(:millisecond) - started
			},
			"read database sync done: #{market_count} market rows"
		)

		:ok
	rescue
		e ->
			Marketmailer.Log.warning(
				"read_sync_failed",
				%{reason: Exception.message(e)},
				"read database sync failed; skipping broadcast"
			)

			{:error, Exception.message(e)}
	catch
		_, reason ->
			Marketmailer.Log.warning(
				"read_sync_failed",
				%{reason: inspect(reason)},
				"read database sync failed; skipping broadcast"
			)

			{:error, inspect(reason)}
	end

	def ensure_read_schema do
		statements = [
			"""
			CREATE TABLE IF NOT EXISTS market (
				order_id INTEGER PRIMARY KEY,
				duration INTEGER,
				is_buy_order BOOLEAN,
				issued TEXT,
				location_id BIGINT,
				min_volume INTEGER,
				price FLOAT,
				"range" TEXT,
				system_id INTEGER,
				type_id INTEGER,
				volume_remain INTEGER,
				volume_total INTEGER,
				inserted_at TEXT,
				updated_at TEXT
			)
			""",
			"CREATE INDEX IF NOT EXISTS market_type_system_buy ON market(type_id, system_id, is_buy_order)",
			"CREATE INDEX IF NOT EXISTS market_price ON market(price)",
			"CREATE INDEX IF NOT EXISTS market_updated_at ON market(updated_at, order_id)",
			"CREATE INDEX IF NOT EXISTS market_jita_buy ON market(type_id) WHERE system_id = 30000142 AND is_buy_order = 1",
			"CREATE INDEX IF NOT EXISTS market_sell_price ON market(type_id, price) WHERE is_buy_order = 0",
			"""
			CREATE TABLE IF NOT EXISTS names (
				id INTEGER PRIMARY KEY,
				name TEXT NOT NULL
			)
			""",
			"""
			CREATE TABLE IF NOT EXISTS systems (
				system_id INTEGER PRIMARY KEY,
				name TEXT NOT NULL,
				security_status FLOAT,
				region_name TEXT NOT NULL
			)
			""",
			"""
			CREATE TABLE IF NOT EXISTS _sync_watermark (
				source_table TEXT PRIMARY KEY,
				updated_at TEXT NOT NULL,
				last_id INTEGER NOT NULL
			)
			""",
			"DROP VIEW IF EXISTS marketListView",
			list_view_sql()
		]

		Enum.each(statements, &ReadDatabase.query!(&1, []))
		:ok
	end

	# Same undercutting view as priv/repo/migrations/..._create_market_list_view.
	def list_view_sql do
		"""
		CREATE VIEW marketListView AS
		WITH JitaBuy AS (
				SELECT
						type_id,
						MAX(price) AS buy_price
				FROM market
				WHERE system_id = 30000142
					AND is_buy_order = 1
				GROUP BY type_id
		)
		SELECT
				tn.name AS item,
				jb.buy_price AS buy_price,
				s.price AS sell_price,
				(jb.buy_price - s.price) AS margin,
				s.order_id,
				s.type_id,
				s.system_id,
				s.location_id,
				s.volume_remain,
				s.volume_total,
				s.issued,
				s.duration,
				s."range",
				sy.name AS system_name,
				sy.security_status,
				sy.region_name,
				ln.name AS location_name
		FROM market s
		JOIN JitaBuy jb ON jb.type_id = s.type_id
		LEFT JOIN names tn ON tn.id = s.type_id
		LEFT JOIN names ln ON ln.id = s.location_id
		LEFT JOIN systems sy ON sy.system_id = s.system_id
		WHERE s.is_buy_order = 0
			AND s.price < jb.buy_price
		"""
	end

	defp copy_caches do
		names = copy_full_table("names", "id", [:id, :name])
		systems = copy_full_table("systems", "system_id", [:system_id, :name, :security_status, :region_name])
		{:ok, names + systems}
	end

	# Small tables, no timestamps: replace the whole read copy every run.
	defp copy_full_table(table, key, columns) do
		cols = Enum.join(columns, ", ")

		rows =
			case Database.query("SELECT #{cols} FROM #{table} ORDER BY #{key}", []) do
				{:ok, %{rows: rows}} -> rows
				{:error, reason} -> raise "cache copy failed for #{table}: #{inspect(reason)}"
			end

		ReadDatabase.query!("DELETE FROM #{table}", [])

		total =
			rows
			|> Enum.chunk_every(@cache_chunk_size)
			|> Enum.reduce(0, fn chunk, acc ->
				maps = Enum.map(chunk, fn row -> columns |> Enum.zip(row) |> Map.new() end)
				{count, _} = ReadDatabase.insert_all(table, maps)
				acc + count
			end)

		total
	end

	defp copy_market_deltas do
		# Seed the cursor at the persisted watermark with an impossible id:
		# boundary rows (updated_at = watermark, e.g. same-second updates
		# from a previous run) are recopied, and paging advances strictly
		# forward from there, so a boundary-heavy table still terminates.
		# The persisted watermark advances only on strictly newer timestamps.
		watermark = read_watermark()
		copy_market_from(%{updated_at: watermark, order_id: -1}, watermark, 0)
	end

	defp copy_market_from(last, watermark, total) do
		cols = Enum.join(@market_fields, ", ")

		rows =
			case Database.query(
						 "SELECT #{cols} FROM market WHERE updated_at > ? OR (updated_at = ? AND order_id > ?) ORDER BY updated_at ASC, order_id ASC LIMIT #{@market_chunk_size}",
						 [to_string(last.updated_at), to_string(last.updated_at), last.order_id]
					 ) do
				{:ok, %{rows: rows}} -> rows
				{:error, reason} -> raise "market delta copy failed: #{inspect(reason)}"
			end

		case rows do
			[] ->
				write_watermark(watermark)
				total

			_ ->
				maps = Enum.map(rows, fn row -> @market_fields |> Enum.zip(row) |> Map.new() end)

				ReadDatabase.insert_all("market", maps,
					on_conflict: {:replace, @market_fields -- [:order_id]},
					conflict_target: :order_id
				)

				new_last = List.last(maps)
				next_watermark = max(watermark, to_string(new_last.updated_at))

				if length(maps) < @market_chunk_size do
					write_watermark(next_watermark)
					total + length(maps)
				else
					copy_market_from(new_last, next_watermark, total + length(maps))
				end
		end
	end

	defp read_watermark do
		case ReadDatabase.query("SELECT updated_at FROM _sync_watermark WHERE source_table = 'market'", []) do
			{:ok, %{rows: [[updated_at]]}} -> to_string(updated_at)
			_ -> ""
		end
	end

	defp write_watermark(updated_at) do
		ReadDatabase.query(
			"INSERT INTO _sync_watermark (source_table, updated_at, last_id) VALUES ('market', ?, -1) ON CONFLICT(source_table) DO UPDATE SET updated_at = excluded.updated_at",
			[to_string(updated_at)]
		)

		:ok
	end
end
