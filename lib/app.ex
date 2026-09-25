defmodule Marketmailer.Application do
	use Application

	@legacy_tables ["systems", "names", "discord", "etags", "market"]

	@impl true
	def start(_type, _args) do
		configure_file_logger()
		Marketmailer.Log.info("app_start", %{booted_at: DateTime.utc_now()}, "marketmailer starting")
		:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])

		:ok = migrate()

		children = [
			Database,
			EtagCache,
			{Registry, keys: :unique, name: Marketmailer.Registry},
			{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
			{Task.Supervisor, name: Marketmailer.TaskSup},
			Janice.Supervisor,
			Marketmailer.RegionManagerSupervisor,
			{Marketmailer.BotSupervisor, Application.fetch_env!(:marketmailer, :bot_options)}
		]

		opts = [
			strategy: :one_for_one,
			name: Marketmailer.Supervisor
		]

		Supervisor.start_link(children, opts)
	end

	# Runs pending priv/repo/migrations on every boot so `mix run`/containers
	# never need a separate migrate step. Databases created before migrations
	# existed have the tables but no schema_migrations bookkeeping; those are
	# dropped once (data is derived cache) and rebuilt.
	defp migrate do
		path = Path.join(:code.priv_dir(:marketmailer), "repo/migrations")

		fun = fn repo ->
			drop_legacy(repo)
			Ecto.Migrator.run(repo, path, :up, all: true)
		end

		case Ecto.Migrator.with_repo(Database, fun) do
			{:ok, _, _} -> :ok
			{:error, error} -> raise "migrations failed: #{inspect(error)}"
		end
	end

	defp drop_legacy(repo) do
		%{rows: rows} =
			repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")

		names = MapSet.new(rows, fn [name] -> name end)

		if MapSet.size(names) > 0 and not MapSet.member?(names, "schema_migrations") do
			Marketmailer.Log.warning(
				"legacy_db_dropped",
				%{tables: @legacy_tables},
				"pre-migration database detected; dropping #{Enum.join(@legacy_tables, ", ")}"
			)

			Enum.each(@legacy_tables, fn table ->
				repo.query!("DROP TABLE IF EXISTS #{table}")
			end)

			repo.query!("DROP VIEW IF EXISTS marketView")
		end
	end

	# Every error-level event is appended as pretty JSON to ./logs/errors.jsonl.
	# logs/ is removed and recreated on every boot so each run starts clean.
	# Rotation keeps the five most recent 10 MB archives, compressed on rotate.
	# A failed handler never stops the app - it only warns (logger_std_h
	# requires a charlist).
	defp configure_file_logger do
		File.rm_rf!("logs")
		File.mkdir_p!("logs")
		file = String.to_charlist(Path.join("logs", "errors.jsonl"))

		config = %{
			config: %{
				type: :file,
				file: file,
				max_no_bytes: 10_000_000,
				max_no_files: 5,
				compress_on_rotate: true,
				filesync_repeat_interval: 1_000
			},
			level: :error,
			formatter: {Marketmailer.Log.Format, [pretty: true, color: false]}
		}

		case :logger.add_handler(:marketmailer_errors, :logger_std_h, config) do
			:ok ->
				:ok

			{:error, {:already_exist, _id}} ->
				:ok

			{:error, reason} ->
				Marketmailer.Log.warning("error_log_handler_failed", %{reason: inspect(reason)})
				:ok
		end
	end
end
