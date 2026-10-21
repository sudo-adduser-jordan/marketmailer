defmodule Marketmailer.Regions do
	@moduledoc """
	SDE region cache.

	`mix sde.import` replaces this table from `mapRegions.jsonl`. The region
	supervisor reads it once at boot, so the poller list always matches the
	SDE instead of a hardcoded id range.
	"""

	import Ecto.Query, only: [from: 2]

	def ids do
		from(r in "regions", select: r.region_id, order_by: r.region_id)
		|> Database.all()
	end
end
