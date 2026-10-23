defmodule Marketmailer.RegionManagerSupervisor do
	use Supervisor

	import Ecto.Query, only: [from: 2]

	@region_ids_key {__MODULE__, :region_ids}

	def region_ids, do: :persistent_term.get(@region_ids_key, [])

	def sde_region_ids do
		from(r in "regions", select: r.region_id, order_by: r.region_id)
		|> Database.all()
	end

	def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_) do
		regions = sde_region_ids()
		:persistent_term.put(@region_ids_key, regions)

		if regions == [] do
			Marketmailer.Log.warning(
				"regions_missing",
				%{},
				"no SDE regions loaded; starting no region managers (run mix sde.import)"
			)
		end

		children =
			for id <- regions do
				Supervisor.child_spec({Marketmailer.RegionManager, id}, id: {:region_manager, id})
			end

		Supervisor.init(children, strategy: :one_for_one)
	end
end
