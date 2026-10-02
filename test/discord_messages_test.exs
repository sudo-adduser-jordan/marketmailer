defmodule Discord.MessagesTest do
	use ExUnit.Case, async: true

	alias MarketView
	alias Nostrum.Struct.Embed

	test "renders a market-not-found failure embed" do
		embed = Discord.Messages.market_not_found_embed("  Rifter  ")

		assert %Embed{title: "Item not found"} = embed
		assert embed.description == "No cached market order was found for **Rifter**."
	end

	test "uses location, sell, buy and margin fields for a market embed" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			location_name: "Jita IV - Moon 4",
			security_status: 0.9,
			price: 10.0,
			buy_price: 110.0,
			instant_sell_profit: 1_000.0
		}

		embed = Discord.Messages.market_embed(item)
		fields = Map.new(embed.fields, &{&1.name, &1.value})

		assert %Embed{title: "Tritanium"} = embed
		assert embed.author == nil
		assert fields["Location"] == "```ansi\n\e[32mJita IV - Moon 4 - Jita - The Forge (0.9)\e[0m\n```"
		assert fields["Sell"] == "```ansi\n\e[32m10.00 ISK\e[0m\n```"
		assert fields["Buy"] == "```ansi\n\e[32m110.00 ISK\e[0m\n```"
		assert fields["Margin"] == "```ansi\n\e[32m+1000.00 ISK\e[0m\n```"
		assert embed.description =~ "janice.e-351.com/i/1001/market/2"
		assert embed.color == 0x43B581
	end

	test "colors loss red and unknown margin neutral" do
		loss = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			price: 120.0,
			buy_price: 110.0,
			instant_sell_profit: -100.0
		}

		loss_embed = Discord.Messages.market_embed(loss)
		loss_fields = Map.new(loss_embed.fields, &{&1.name, &1.value})

		assert loss_fields["Margin"] == "```ansi\n\e[31m-100.00 ISK\e[0m\n```"
		assert loss_embed.color == 0xF04747

		unknown = %MarketView{type_id: 1_001, item_name: "Tritanium", price: 10.0}

		unknown_embed = Discord.Messages.market_embed(unknown)
		unknown_fields = Map.new(unknown_embed.fields, &{&1.name, &1.value})

		assert unknown_fields["Buy"] == "```ansi\n\e[90m? ISK\e[0m\n```"
		assert unknown_fields["Margin"] == "```ansi\n\e[90m? ISK\e[0m\n```"
		assert unknown_fields["Location"] == "```ansi\n\e[90m? - ? - ? (?)\e[0m\n```"
		assert unknown_embed.color == 0x7289DA
	end

	test "places the Janice graph in the image slot, keeping the item icon" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0
		}

		embed = Discord.Messages.market_embed(item, nil, "attachment://janice-1001.png")

		assert embed.image.url == "attachment://janice-1001.png"
		assert embed.thumbnail.url == "https://images.evetech.net/types/1001/icon?size=64"
	end

	test "defaults the thumbnail to the item's EVE image-server icon" do
		item = %MarketView{
			type_id: 81_008,
			item_name: "Squall",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0
		}

		embed = Discord.Messages.market_embed(item)

		assert embed.thumbnail.url == "https://images.evetech.net/types/81008/icon?size=64"
	end

	test "colors location by security and keeps station-system-region order" do
		base = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			location_name: "Jita IV - Moon 4",
			price: 10.0
		}

		high = Discord.Messages.market_embed(%{base | security_status: 0.9})
		low = Discord.Messages.market_embed(%{base | security_status: 0.3})
		null = Discord.Messages.market_embed(%{base | security_status: -0.5})

		fields = fn embed -> Map.new(embed.fields, &{&1.name, &1.value}) end

		assert fields.(high)["Location"] ==
						"```ansi\n\e[32mJita IV - Moon 4 - Jita - The Forge (0.9)\e[0m\n```"

		assert fields.(low)["Location"] ==
						"```ansi\n\e[33mJita IV - Moon 4 - Jita - The Forge (0.3)\e[0m\n```"

		assert fields.(null)["Location"] ==
						"```ansi\n\e[31mJita IV - Moon 4 - Jita - The Forge (-0.5)\e[0m\n```"
	end

	test "all embeds carry a SemVer version badge in the footer" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0,
			instant_sell_profit: nil
		}

		embeds = [
			Discord.Messages.server_only(%{}),
			Discord.Messages.error(%{}),
			Discord.Messages.market_not_found_embed("Rifter"),
			Discord.Messages.market_list_embed([]),
			Discord.Messages.market_embed(item),
			Discord.Messages.add_channel(%{channel_id: 123}),
			Discord.Messages.channel_removed(%{channel_id: 123}),
			Discord.Messages.list_channel(%{channel_id: 123}),
			Discord.Messages.list_channel(nil)
		]

		assert length(embeds) == 9

		for embed <- embeds do
			assert %Embed{footer: %Embed.Footer{text: text}} = embed
			assert text =~ ~r/^Marketmailer v\d+\.\d+\.\d+$/
		end
	end
end
