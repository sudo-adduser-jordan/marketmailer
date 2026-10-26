defmodule Database.Migrations.PurgeGhostMarketOrders do
	use Ecto.Migration

	# Rows written before the url column existed (20261019000000) carry
	# url IS NULL. The per-page stale sweep in Market.Database only deletes
	# rows matching the fetched page url, so NULL-url rows are never swept
	# even after their page refreshes without them — and url is excluded
	# from change detection, so a re-fetch never backfills it either. Dead
	# orders therefore accumulate forever and poison the Jita buy-wall view
	# with crossed books that cannot exist in-game (e.g. a live Jita sell
	# resting under a long-dead Jita buy). Any row still listed by ESI is
	# re-inserted with its page url on the next refresh, so the purge is
	# self-healing; only ghosts never come back.
	def up do
		execute("DELETE FROM market WHERE url IS NULL")
	end

	# Irreversible: purged ghost rows cannot be restored. Live rows
	# re-appear on the next poller cycle.
	def down do
	end
end
