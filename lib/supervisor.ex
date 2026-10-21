defmodule Marketmailer.RegionManagerSupervisor do
	use Supervisor

	# The started set is cached here because Discord.Broadcaster waits for one
	# report per id in this list. It must match the managers that actually run:
	# a live DB read could include a region imported after boot that has no
	# manager behind it, and the round barrier would never close.
	@region_ids_key {__MODULE__, :region_ids}

	def region_ids, do: :persistent_term.get(@region_ids_key, [])

	def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_) do
		regions = Marketmailer.Regions.ids()
		:persistent_term.put(@region_ids_key, regions)

		if regions == [] do
			Marketmailer.Log.warning(
				"regions_missing",
				%{},
				"no SDE regions loaded; starting no region managers (run mix sde.import)"
			)
		else
			Marketmailer.Log.info(
				"regions_loaded",
				%{regions: length(regions)},
				"starting one region manager per SDE region"
			)
		end

		children =
			for id <- regions do
				Supervisor.child_spec({Marketmailer.RegionManager, id}, id: {:region_manager, id})
			end

		Supervisor.init(children, strategy: :one_for_one)
	end
end
