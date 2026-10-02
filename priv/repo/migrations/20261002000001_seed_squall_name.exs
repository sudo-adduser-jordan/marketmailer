defmodule Database.Migrations.SeedSquallName do
	use Ecto.Migration

	# Squall (type 81008) has cached market rows yet its name row can be
	# absent from the lazy `names` cache, which makes getMarketItem.sql filter
	# it out via `tn.name IS NOT NULL`. Seed it so Squall lookups never miss.
	def up do
		execute("INSERT OR IGNORE INTO names (id, name) VALUES (81008, 'Squall')")
	end

	def down do
		execute("DELETE FROM names WHERE id = 81008")
	end
end
