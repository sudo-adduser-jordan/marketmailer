defmodule Database.Migrations.SeedJitaDisplayRows do
	use Ecto.Migration

	# check_market is pinned to Jita 4-4, so its Location line only ever
	# needs these two display rows. Seeded statically so the embed is
	# complete from first boot while the background ticker fills the rest.
	def up do
		execute(
			"INSERT OR IGNORE INTO systems (system_id, name, security_status, region_name) VALUES (30000142, 'Jita', 0.9, 'The Forge')"
		)

		execute(
			"INSERT OR IGNORE INTO names (id, name) VALUES (60003760, 'Jita IV - Moon 4 - Caldari Navy Assembly Plant')"
		)
	end

	def down do
		execute("DELETE FROM systems WHERE system_id = 30000142")
		execute("DELETE FROM names WHERE id = 60003760")
	end
end
