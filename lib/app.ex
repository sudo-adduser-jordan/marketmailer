defmodule Marketmailer.Application do
	use Application

	@default_error_log_path "logs/errors.jsonl"
	@log_handler :marketmailer_errors

	@impl true
	def start(_type, _args) do
		configure_file_logger()
		Marketmailer.Log.info("app_start", %{booted_at: DateTime.utc_now()}, "marketmailer starting")
		create_cache_if_not_exists(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		create_cache_if_not_exists(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])
		create_cache_if_not_exists(:esi_rate_state, [:named_table, :set, :public, read_concurrency: true])
		create_cache_if_not_exists(:network_state, [:named_table, :set, :public, read_concurrency: true])
		create_cache_if_not_exists(:janice_chart_cache, [:named_table, :set, :public])

		:ok = Database.Migrations.run!()

		children =
			[
				Database,
				Database.Queue,
				Marketmailer.Maintenance,
				EtagCache,
				{Registry, keys: :unique, name: Marketmailer.Registry},
				{Task.Supervisor, name: Marketmailer.TaskSup}
			] ++
				poller_core_children() ++
				[Janice.Supervisor] ++
				dashboard_children() ++
				bot_children()

		opts = [
			strategy: :one_for_one,
			name: Marketmailer.Supervisor
		]

		{:ok, pid} = Supervisor.start_link(children, opts)

		Market.Database.log_unnamed_undercut_types()

		{:ok, pid}
	end

	defp poller_core_children do
		if pollers_enabled?() do
			[
				{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
				Marketmailer.RegionManagerSupervisor
			] ++
				contracts_children() ++
				[
					Discord.Broadcaster
				]
		else
			[]
		end
	end

	defp contracts_children do
		if Contracts.enabled?() do
			[
				{DynamicSupervisor, strategy: :one_for_one, name: Contracts.PageSup},
				Contracts.RegionManagerSupervisor,
				Contracts.ItemGate,
				Contracts.Manager
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

	defp create_cache_if_not_exists(name, opts) do
		case :ets.whereis(name) do
			:undefined -> :ets.new(name, opts)
			_tid -> :ok
		end
	end

	defp configure_file_logger do
		path = error_log_path()
		reset_error_log(path)
		ensure_file_logger(path)
	end

	def error_log_path do
		Application.get_env(:marketmailer, :error_log_path, @default_error_log_path)
	end

	def reset_error_log(path) do
		_ = File.rm(path)

		case File.ls(Path.dirname(path)) do
			{:ok, entries} ->
				prefix = Path.basename(path)
				dir = Path.dirname(path)

				for entry <- entries, String.starts_with?(entry, prefix), do: File.rm(Path.join(dir, entry))

			_ ->
				:ok
		end

		:ok
	end

	def ensure_file_logger(path \\ error_log_path(), handler \\ @log_handler) do
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
