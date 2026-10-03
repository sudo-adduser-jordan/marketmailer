defmodule Marketmailer.Application do
	use Application

	@legacy_tables ["systems", "names", "discord", "etags", "market"]
	@log_dir "logs"
	@log_file "logs/errors.jsonl"
	@log_handler :marketmailer_errors

	@impl true
	def start(_type, _args) do
		configure_file_logger()
		Marketmailer.Log.info("app_start", %{booted_at: DateTime.utc_now()}, "marketmailer starting")
		ensure_ets(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		ensure_ets(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])
		ensure_ets(:janice_chart_cache, [:named_table, :set, :public])

		:ok = migrate()

		children =
			[
				Database,
				Market.DbWriter,
				EtagCache,
				{Registry, keys: :unique, name: Marketmailer.Registry},
				{Task.Supervisor, name: Marketmailer.TaskSup},
				Market.UpdateCoordinator,
				Discord.Broadcaster,
				Janice.Supervisor
			] ++ dashboard_children() ++ poller_children()

		opts = [
			strategy: :one_for_one,
			name: Marketmailer.Supervisor
		]

		{:ok, pid} = Supervisor.start_link(children, opts)

		# Fire-and-forget: bulk universe/names calls caching every polled
		# region id plus every traded type id, so single-item lookups stay
		# pure DB queries. Skipped when pollers are disabled (e.g. `config/test.exs`).
		# The type fill ticks forever in small batches: at boot every page
		# worker stampedes ESI at once, so one big fill would starve behind
		# the swarm; steady 500-id ticks drain the ~18k backlog within the
		# hour and then idle on a cheap empty query.
		if pollers_enabled?() do
			# Independent tasks: region seeding can stall behind the boot
			# ESI stampede and must never head-of-line-block the type fill.
			Task.start(fn ->
				Universe.Database.seed_region_names(Marketmailer.RegionManagerSupervisor.region_ids())
			end)

			Task.start(fn -> seed_type_names_forever() end)
		end

		{:ok, pid}
	end

	# Steady background fill of the names cache: one small bounded batch per
	# minute, forever. Each tick is at most one ESI chunk; once the backlog
	# drains the tick is a single indexed no-op query.
	defp seed_type_names_forever do
		count = Universe.Database.missing_type_name_count()
		started = System.monotonic_time(:millisecond)

		Marketmailer.Log.info(
			"type_names_tick",
			%{missing: count},
			"type-name fill tick: #{count} missing"
		)

		if count != 0 do
			Universe.Database.seed_missing_type_names(500)
			Universe.Database.seed_missing_location_names(500)
			Universe.Database.seed_missing_systems(20)
		end

		Marketmailer.Log.info(
			"type_names_tick_done",
			%{missing: count, elapsed_ms: System.monotonic_time(:millisecond) - started},
			"type-name fill tick done"
		)

		Process.sleep(60_000)
		seed_type_names_forever()
	end

	# Test env (`config/test.exs`: `start_pollers: false`) boots only the
	# database/cache leaves so `mix test` never hits live ESI or Discord.
	defp poller_children do
		if pollers_enabled?() do
			[
				{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
				Marketmailer.RegionManagerSupervisor,
				{Marketmailer.BotSupervisor, Application.fetch_env!(:marketmailer, :bot_options)}
			]
		else
			[]
		end
	end

	defp pollers_enabled?, do: Application.get_env(:marketmailer, :start_pollers, true)

	# Phoenix LiveDashboard (`/dashboard`): PubSub + telemetry poller +
	# HTTP endpoint. Disabled in test (`config/test.exs`) and when
	# `DASHBOARD_ENABLED=false` in prod (`config/runtime.exs`).
	defp dashboard_children do
		if dashboard_enabled?() do
			[
				{Phoenix.PubSub, name: Marketmailer.PubSub},
				MarketmailerWeb.Telemetry,
				MarketmailerWeb.Endpoint
			]
		else
			[]
		end
	end

	defp dashboard_enabled?, do: Application.get_env(:marketmailer, :dashboard_enabled, true)

	defp ensure_ets(name, opts) do
		case :ets.whereis(name) do
			:undefined -> :ets.new(name, opts)
			_tid -> :ok
		end
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

	# Every warning/error-level event is appended as pretty JSON to ./logs/errors.jsonl.
	# logs/ is removed and recreated on every boot so each run starts clean.
	# Rotation keeps the five most recent 10 MB archives, compressed on rotate.
	# A failed handler never stops the app - it only warns (logger_std_h
	# requires a charlist).
	# While running, :logger_std_h holds the log file descriptor open: deleting
	# logs/errors.jsonl (or logs/) orphans the descriptor and no new file
	# appears. ensure_file_logger/0 is idempotent and non-destructive —
	# PageWorker calls it on every fetch so a deleted log is recreated within
	# one cycle.
	defp configure_file_logger do
		File.rm_rf!(@log_dir)
		ensure_file_logger()
	end

	@doc """
	Recreates the file log (dir + `:logger_std_h` handler) when it was deleted
	while running. Cheap no-op when healthy: one `stat` plus a handler lookup.
	Public so supervised workers and `remote` shells can call it. The optional
	args exist for tests so they never touch the real `logs/errors.jsonl`.
	"""
	def ensure_file_logger(path \\ @log_file, handler \\ @log_handler) do
		File.mkdir_p!(Path.dirname(path))

		if handler_healthy?(handler, path) do
			:ok
		else
			# Drop the orphan-fd handler (if any) so the re-added one opens the
			# fresh path.
			:logger.remove_handler(handler)
			add_file_handler(handler, path)
		end
	rescue
		_ -> :ok
	end

	defp handler_healthy?(handler, path) do
		File.exists?(path) and match?({:ok, _}, :logger.get_handler_config(handler))
	end

	defp add_file_handler(handler, path) do
		config = %{
			config: %{
				type: :file,
				file: String.to_charlist(path),
				max_no_bytes: 10_000_000,
				max_no_files: 5,
				compress_on_rotate: true,
				filesync_repeat_interval: 1_000
			},
			level: :warning,
			formatter: {Marketmailer.Log.Format, [pretty: true, color: false]}
		}

		case :logger.add_handler(handler, :logger_std_h, config) do
			:ok ->
				:ok

			{:error, {:already_exist, _}} ->
				:logger.remove_handler(handler)

				case :logger.add_handler(handler, :logger_std_h, config) do
					:ok -> :ok
					{:error, reason} -> handler_failed(reason)
				end

			{:error, reason} ->
				handler_failed(reason)
		end
	end

	defp handler_failed(reason) do
		Marketmailer.Log.warning("error_log_handler_failed", %{reason: inspect(reason)})
		:ok
	end
end
