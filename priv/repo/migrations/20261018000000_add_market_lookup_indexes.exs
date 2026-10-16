defmodule Database.Migrations.AddMarketLookupIndexes do
	use Ecto.Migration

	def change do
		create_if_not_exists index(:market, [:location_id, :is_buy_order, :type_id])

		create_if_not_exists index(:market, [:type_id, :price, :volume_remain],
													 where: "system_id = 30000142 AND is_buy_order = 1"
												 )
	end
end
