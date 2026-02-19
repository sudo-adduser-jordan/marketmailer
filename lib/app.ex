defmodule Marketmailer.Application do
	use Application

	@impl true
	def start(_type, _args) do
		:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])

		children = [
			Database,
			EtagCache,
			{Registry, keys: :unique, name: Marketmailer.Registry},
			{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
			{Task.Supervisor, name: Marketmailer.TaskSup},
			# Marketmailer.RegionManagerSupervisor,
			# Marketmailer.MailWorker,
			{Nostrum.Bot, Application.fetch_env!(:marketmailer, :bot_options)}
		]

		opts = [
			strategy: :one_for_one,
			name: Marketmailer.Supervisor
		]

		Supervisor.start_link(children, opts)
	end
end
