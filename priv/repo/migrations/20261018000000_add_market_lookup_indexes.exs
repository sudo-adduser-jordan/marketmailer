defmodule Database.Migrations.AddMarketLookupIndexes do
	use Ecto.Migration

	# check_market runs suggest_items + get_market_item synchronously before it
	# acknowledges the interaction, which must land inside Discord's 3s window.
	# Both queries seek the Jita 4-4 sell set (station 60003760) and the Jita
	# buy wall (system 30000142); without these the planner scans the whole
	# ~1.3M-row market table and the pair takes ~3.5s, so the late ACK is
	# dropped ("The application did not respond") and the follow-up chart edit
	# then 404s with "Unknown Webhook".
	def change do
		create_if_not_exists index(:market, [:location_id, :is_buy_order, :type_id])

		create_if_not_exists index(:market, [:type_id, :price, :volume_remain],
													 where: "system_id = 30000142 AND is_buy_order = 1"
												 )
	end
end
