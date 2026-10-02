defmodule Database.Migrations.SeedPlexName do
	use Ecto.Migration

	# PLEX (type 44992) always has cached market rows yet its name row can be
	# absent from the lazy `names` cache, which makes getMarketItem.sql filter
	# it out via `tn.name IS NOT NULL`. Seed it so PLEX lookups never miss.
	def up do
		execute("INSERT OR IGNORE INTO names (id, name) VALUES (44992, 'PLEX')")
	end

	def down do
		execute("DELETE FROM names WHERE id = 44992")
	end
end
