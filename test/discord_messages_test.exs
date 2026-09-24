defmodule Discord.MessagesTest do
	use ExUnit.Case, async: true

	alias MarketView
	alias Nostrum.Struct.Embed

	test "renders a market-not-found failure embed" do
		embed = Discord.Messages.market_not_found_embed("  Rifter  ")

		assert %Embed{title: "Item not found"} = embed
		assert embed.description == "No cached market order was found for **Rifter**."
	end

	test "uses the item name and sell price for a market embed" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0,
			instant_sell_profit: nil
		}

		embed = Discord.Messages.market_embed(item)
		price_field = Enum.find(embed.fields, &(&1.name == "Sell price"))

		assert %Embed{title: "Tritanium"} = embed
		assert price_field.value == "10.00 ISK"
		assert embed.description =~ "janice.e-351.com/i/1001/market/2"
	end
end
