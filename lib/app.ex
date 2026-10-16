defmodule Marketmailer.Application do
	use Application

	@unmigrated_tables ["systems", "names", "discord", "etags", "market"]
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
				Database.Queue,
				EtagCache,
				{Registry, keys: :unique, name: Marketmailer.Registry},
				{Task.Supervisor, name: Marketmailer.TaskSup}
			] ++ poller_core_children() ++ [Discord.Broadcaster, Janice.Supervisor] ++ dashboard_children() ++ bot_children()

		opts = [
			strategy: :one_for_one,
			name: Marketmailer.Supervisor
		]

		{:ok, pid} = Supervisor.start_link(children, opts)

		{:ok, pid}
	end

	defp poller_core_children do
		if pollers_enabled?() do
			[
				{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
				Marketmailer.RegionManagerSupervisor
			]
		else
			[]
		end
	end

	defp bot_children do
		if pollers_enabled?() do
			[{Discord.BotSupervisor, Application.fetch_env!(:marketmailer, :bot_options)}]
		else
			[]
		end
	end

	defp pollers_enabled?, do: Application.get_env(:marketmailer, :start_pollers, true)

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

	defp migrate do
		path = Path.join(:code.priv_dir(:marketmailer), "repo/migrations")

		fun = fn repo ->
			drop_unmigrated(repo)
			Ecto.Migrator.run(repo, path, :up, all: true)
		end

		case Ecto.Migrator.with_repo(Database, fun) do
			{:ok, _, _} -> :ok
			{:error, error} -> raise "migrations failed: #{inspect(error)}"
		end
	end

	defp drop_unmigrated(repo) do
		%{rows: rows} =
			repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")

		names = MapSet.new(rows, fn [name] -> name end)

		if MapSet.size(names) > 0 and not MapSet.member?(names, "schema_migrations") do
			Marketmailer.Log.warning(
				"unmigrated_db_dropped",
				%{tables: @unmigrated_tables},
				"pre-migration database detected; dropping #{Enum.join(@unmigrated_tables, ", ")}"
			)

			Enum.each(@unmigrated_tables, fn table ->
				repo.query!("DROP TABLE IF EXISTS #{table}")
			end)

			repo.query!("DROP VIEW IF EXISTS marketView")
		end
	end

	defp configure_file_logger do
		File.rm_rf!(@log_dir)
		ensure_file_logger()
	end

	def ensure_file_logger(path \\ @log_file, handler \\ @log_handler) do
		File.mkdir_p!(Path.dirname(path))

		if handler_healthy?(handler, path) do
			:ok
		else
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
			formatter: {Marketmailer.Log.Format, %{pretty: true, color: false}}
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
