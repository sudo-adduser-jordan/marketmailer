defmodule Marketmailer.RegionManagerSupervisor do
		use Supervisor

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
		def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

		@impl true
		def init(_) do
				children =
						for id <- @regions,
										do: Supervisor.child_spec({Marketmailer.RegionManager, id}, id: {:region_manager, id})

				Supervisor.init(children, strategy: :one_for_one)
		end
end
