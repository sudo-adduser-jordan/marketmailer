defmodule Discord.Messages do
	# alias Nostrum.Cache.GuildCache
	alias Nostrum.Struct.Embed
	# alias Nostrum.Struct.Guild
	alias Nostrum.Struct.Interaction

	@color_blurple 0x7289DA
	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	# https://images.evetech.net/{category}/{id}/{variation}

	# @icon_ "https://pic.vsixhub.com/e5/91/cweijan.vscode-myssql-client2-logo-20251008.webp"
	# @icon_ "https://images.evetech.net/types/52996/relic?size=64"
	# @icon_corporation "https://images.evetech.net/corporations/98666181/logo?size=64"
	@icon_elixir "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/elixir.png"
	@icon_market "https://cdn.cgmagonline.com/wp-content/uploads/2025/10/latest-expansion-eve-online-catalyst-announced-by-ccp-games-2025-10-20-667140.jpg"

	@icon_info ""
	@icon_error ""
	@icon_success ""

	# @icon_ ""
	# @icon_ ""
	# @icon_ ""
	# @icon_ ""

	def market_embed do
		%Embed{
			title: "Best Order",
			description: "
						[Hyperlinks](https://discord.com)
						[Hyperlinks](https://discord.com)
						[Hyperlinks](https://discord.com)
						[Hyperlinks](https://discord.com)
						[Hyperlinks](https://discord.com)
						",
			url: "https://discord.com",
			color: 0x7289DA,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_elixir
			},
			thumbnail: %Embed.Thumbnail{
				url: @icon_elixir
			},
			image: %Embed.Image{
				url: ""
			},
			fields: [
				%Embed.Field{
					name: "69%",
					value: "69 420 ISK",
					inline: true
				},
				%Embed.Field{
					name: "The Forge",
					value: "1.0 Jita",
					inline: true
				},
				%Embed.Field{
					name: "Field 3 (Standard)",
					value: "I take up the full width because inline is false.",
					inline: false
				}
			],
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def channel_registered(interaction) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_elixir
			},
			title: "Channel Registiration",
			description: "<##{interaction.id}> is now registered for market alerts.",
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
			description: "<##{interaction.id}> will no longer recieve market alerts.",
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

	def list_channel(interaction) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_elixir
			},
			title: "Channel Registiration",
			description: "<##{interaction.id}> is registered to recieve market alerts.",
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
				# Discord.Database.upsert(interaction.guild_id, interaction)
				respond(interaction, Messages.channel_registered(interaction))

			"remove_channel" ->
				# Discord.Database.delete(interaction.guild_id)
				respond(interaction, Messages.channel_removed(interaction))

			"list_channel" ->
				# Discord.Database.get(interaction.guild_id)
				respond(interaction, Messages.list_channel(interaction))

			"check_market" ->
				# Api.Interaction.create_response(interaction, %{type: 5})
				# items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)
				# Api.Interaction.edit_response(interaction, %{embeds: [Messages.market_embed(items)]})
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
