defmodule Database.Migrations.NormalizeContractItemsFetched do
	use Ecto.Migration

	def up do
		execute("UPDATE contracts SET items_fetched = 1 WHERE items_fetched = 'true'")
		execute("UPDATE contracts SET items_fetched = 0 WHERE items_fetched = 'false'")
	end

	def down do
		:ok
	end
end