defmodule Discord.Messages do
	# alias Nostrum.Cache.GuildCache
	alias Nostrum.Struct.Embed
	# alias Nostrum.Struct.Guild
	alias Nostrum.Struct.Interaction

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	# @icon_ "https://images.evetech.net/types/52996/relic?size=64"
	# @icon_corporation "https://images.evetech.net/corporations/98666181/logo?size=64"

	@icon_ "https://images.evetech.net/types/81008/icon?size=64"
	@icon_elixir "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/elixir.png"
	@icon_market "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/background.png"

	@icon_info "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/broadcast.png"
	@icon_error "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/success.png"
	@icon_success "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/success.png"

	def market_embed do
		# _market_context = Market.Database.cheapest_order() # get row
		market_url = "https://janice.e-351.com/i/81008/market/2"
		reference_url = "https://everef.net/types/81008"

		%Embed{
			title: "Squall",
			description: "
						[Market](#{market_url}) [Reference](#{reference_url})
						",
			# url: "https://discord.com",
			color: 0x7289DA,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer - Best Order",
				url: "https://discord.com",
				icon_url: @icon_success
			},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			},
			image: %Embed.Image{
				url: @icon_market
			},
			fields: [
				%Embed.Field{
					name: "The Forge",
					value: "1.0 Jita",
					inline: true
				},
				%Embed.Field{
					name: "69%",
					value: "69 420 ISK",
					inline: true
				}
			],
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def add_channel(interaction) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_elixir
			},
			title: "Channel Registiration",
			description: "<##{interaction.channel_id}> is now registered for market alerts.",
			url: "https://discord.com",
			color: @color_success,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_elixir
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def channel_removed(interaction) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_elixir
			},
			title: "Channel Registiration",
			description: "<##{interaction.channel_id}> will no longer recieve market alerts.",
			url: "https://discord.com",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_elixir
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def list_channel(record) do
		channel_id = if record, do: record.channel_id

		description =
			if channel_id do
				"<##{channel_id}> is registered to receive market alerts."
			else
				"No channel has been registered for this server yet."
			end

		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_elixir
			},
			title: "Channel Registiration",
			description: description,
			url: "https://discord.com",
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_elixir
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end
end

defmodule Discord.Consumer do
	@behaviour Nostrum.Consumer

	alias Discord.Messages
	alias Nostrum.Api
	alias Nostrum.Struct.Interaction

	@admin_only "16"
	@interval 15 * 60 * 1000

	defp schedule_broadcast, do: Process.send_after(self(), :broadcast, @interval)

	def handle_event({:READY, _, _}) do
		commands = [
			%{name: "add_channel", description: "Set current channel for alerts", default_member_permissions: @admin_only},
			%{name: "remove_channel", description: "Remove alerts from this server", default_member_permissions: @admin_only},
			%{name: "list_channel", description: "Show the current update channel"},
			%{name: "check_market", description: "Scan the market immediately"}
		]

		Api.ApplicationCommand.bulk_overwrite_global_commands(commands)
		schedule_broadcast()
	end

	def handle_event({:INTERACTION_CREATE, %Interaction{data: %{name: name}} = interaction, _}) do
		case name do
			"add_channel" ->
				Discord.Database.upsert(interaction.guild_id, interaction.channel_id)
				respond(interaction, Messages.add_channel(interaction))

			"remove_channel" ->
				Discord.Database.delete(interaction.guild_id)
				respond(interaction, Messages.channel_removed(interaction))

			"list_channel" ->
				channel_id = Discord.Database.get(interaction.guild_id)
				respond(interaction, Messages.list_channel(channel_id))

			"check_market" ->
				respond(interaction, Messages.market_embed())
		end
	end

	def handle_event(_), do: :ok

	# --- Helpers ---

	defp respond(intr, %Nostrum.Struct.Embed{} = embed) do
		Api.Interaction.create_response(intr, %{
			type: 4,
			data: %{embeds: [embed]}
		})
	end

	def handle_info(:broadcast, state) do
		# items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)

		# if items != [] do
		# 	embed = Messages.market_embed(items)

		# 	Enum.each(Discord.Database.all(), fn record ->
		# 		Api.Message.create(record.channel_id, embeds: [embed])
		# 	end)
		# end

		schedule_broadcast()
		{:noreply, state}
	end
end
