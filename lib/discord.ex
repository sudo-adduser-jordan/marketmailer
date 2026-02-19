defmodule Discord.Messages do
	alias Nostrum.Struct.Embed

	@color_blurple 0x7289DA
	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	# https://images.evetech.net/{category}/{id}/{variation}

	@icon_ ""
	@icon_market "https://images.evetech.net/types/30752/relic?size=64"
	@icon_elixir "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/elixir.png"

	@icon_info ""
	@icon_error ""
	@icon_success ""

	# @icon_ ""
	# @icon_ ""
	# @icon_ ""
	# @icon_ ""

	def market_embed do
		%Embed{
			title: "🚀 Full Spec Embed Title",
			description: "This is the main body text. Supports **Markdown** and [Hyperlinks](https://discord.com).",
			url: "https://google.com",
			color: 0x7289DA,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Gemini AI Assistant",
				url: "https://discord.com",
				icon_url: "https://i.imgur.com/vHq4V9n.png"
			},
			thumbnail: %Embed.Thumbnail{
				url: "https://images.evetech.net/types/34/icon?size=64"
			},
			image: %Embed.Image{
				url: "https://i.imgur.com/W9vU0xX.png"
			},
			fields: [
				%Embed.Field{
					name: "Field 1 (Inline)",
					value: "Max 1024 characters.",
					inline: true
				},
				%Embed.Field{
					name: "Field 2 (Inline)",
					value: "I sit next to Field 1.",
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
				icon_url: "https://i.imgur.com/vHq4V9n.png"
			}
		}
	end

	def channel_registered(id) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_market
			},
			title: "Channel Registiration",
			description: "<##{id}> is now registered for market alerts.",
			url: "https://google.com",
			color: @color_success,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_market
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def channel_removed(id) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_market
			},
			title: "Channel Registiration",
			description: "<##{id}> will no longer recieve market alerts.",
			url: "https://google.com",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_market
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def list_channel(id) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_market
			},
			title: "Channel Registiration",
			description: "<##{id}> is the currently registered.",
			url: "https://google.com",
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_market
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

	def handle_event({:INTERACTION_CREATE, %Interaction{data: %{name: name}} = intr, _}) do
		case name do
			"add_channel" ->
				# Discord.Database.upsert(intr.guild_id, intr.channel_id)
				respond(intr, Messages.channel_registered(intr.channel_id))

			"remove_channel" ->
				# Discord.Database.delete(intr.guild_id)
				respond(intr, Messages.channel_removed(intr.channel_id))

			"list_channel" ->
				# Discord.Database.get(intr.guild_id)
				respond(intr, Messages.list_channel(nil))

			"check_market" ->
				# Api.Interaction.create_response(intr, %{type: 5})
				# items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)
				# Api.Interaction.edit_response(intr, %{embeds: [Messages.market_embed(items)]})
				respond(intr, Messages.market_embed())
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
