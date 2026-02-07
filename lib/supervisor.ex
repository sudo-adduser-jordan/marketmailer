defmodule Marketmailer.RegionManagerSupervisor do
	use Supervisor

	def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_) do
		children =
			for id <- Marketmailer.Application.regions(),
					do: Supervisor.child_spec({Marketmailer.RegionManager, id}, id: {:region_manager, id})

		Supervisor.init(children, strategy: :one_for_one)
	end
end
