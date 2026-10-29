defmodule Marketmailer.Application do
	use Application

	@impl true
	def start(_type, _args) do
		Marketmailer.Log.setup()
		Marketmailer.Log.info("app_start", %{booted_at: rfc3339_ms(DateTime.utc_now())}, "marketmailer starting")
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
				ESI.Maintenance,
				EtagCache,
				{Registry, keys: :unique, name: Marketmailer.Registry},
				{Task.Supervisor, name: Marketmailer.TaskSup},
				{Finch,
				 name: ESI.Finch,
				 pools: %{
					 default: [
						 size: 256,
						 count: 8,
						 conn_max_idle_time: 15_000,
						 conn_opts: [
							 transport_opts: [
								 keepalive: true,
								 nodelay: true,
								 timeout: Marketmailer.Maintenance.request_timeout_ms()
							 ]
						 ]
					 ]
				 }}
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
				page_sup(),
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

	defp page_sup do
		{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup, max_restarts: 10_000, max_seconds: 60}
	end

	defp contracts_children do
		if Contracts.enabled?() do
			[
				{DynamicSupervisor, strategy: :one_for_one, name: Contracts.PageSup},
				Contracts.RegionManagerSupervisor,
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

	defp rfc3339_ms(datetime) do
		datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
	end
end
