defmodule Marketmailer.Application do
		use Application

		@user_agent "lostcoastwizard > BEAM me up, Scotty!"
		@regions [
													10_000_001..10_000_070,
													[10_001_000],
													11_000_001..11_000_033,
													12_000_001..12_000_005,
													14_000_001..14_000_005,
													[19_000_001]
											]
											|> Enum.concat()
											|> Enum.to_list()

		def user_agent, do: @user_agent
		def regions, do: @regions

		@impl true
		def start(_type, _args) do
				:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
				:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])

				children = [
						Marketmailer.Database,
						{Registry, keys: :unique, name: Marketmailer.Registry},
						{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
						{Task.Supervisor, name: Marketmailer.TaskSup},
						Marketmailer.RegionManagerSupervisor,
						Marketmailer.EtagWarmup,
						Marketmailer.MailWorker
				]

				opts = [
						strategy: :one_for_one,
						name: Marketmailer.Supervisor
				]

				Supervisor.start_link(children, opts)
		end
end
