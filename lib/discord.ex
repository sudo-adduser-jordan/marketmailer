defmodule Discord.Messages do
	alias Nostrum.Struct.Embed

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	@icon_success "https://i.imgur.com/vHq4V9n.png"
	@icon_error "https://i.imgur.com/6F6O7Wv.png"
	@icon_market "https://images.evetech.net/types/34/icon?size=64"

	def full_spec_embed do
		%Embed{
			# Main Content
			title: "🚀 Full Spec Embed Title",
			description: "This is the main body text. Supports **Markdown** and [Hyperlinks](https://discord.com).",
			# Makes the Title a clickable link
			url: "https://google.com",
			# Hex integer (Blurple)
			color: 0x7289DA,
			# ISO8601 string
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),

			# Author Section (Top of embed)
			author: %Embed.Author{
				name: "Gemini AI Assistant",
				url: "https://discord.com",
				icon_url: "https://i.imgur.com/vHq4V9n.png"
			},

			# Thumbnail (Small image in top-right corner)
			thumbnail: %Embed.Thumbnail{
				url: "https://images.evetech.net/types/34/icon?size=64"
			},

			# Main Image (Large image at the bottom)
			image: %Embed.Image{
				url: "https://i.imgur.com/W9vU0xX.png"
			},

			# Fields (Up to 25 per embed)
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

			# Footer Section (Very bottom)
			footer: %Embed.Footer{
				text: "Sent via Elixir • Nostrum",
				icon_url: "https://i.imgur.com/vHq4V9n.png"
			}
		}
	end

	def channel_registered(id) do
		%Embed{
			description: "✅ Channel <##{id}> is now registered for market alerts.",
			color: @color_success,
			thumbnail: %Embed.Thumbnail{url: @icon_success}
		}
	end

	def channel_removed(id) do
		%Embed{
			description: "🗑️ Market alerts have been disabled for Channel <##{id}>.",
			color: @color_error,
			thumbnail: %Embed.Thumbnail{url: @icon_error}
		}
	end

	def list_channel(nil) do
		%Embed{
			description: "❌ Error: No channel registered. Use `/add_channel` to start.",
			color: @color_error
		}
	end

	def list_channel(id) do
		%Embed{
			description: "📋 Monitoring alerts in <##{id}>",
			color: @color_info,
			author: %Embed.Author{name: "Settings", icon_url: @icon_success}
		}
	end

	def market_embed([]), do: %Embed{description: "❌ Error: Unable to check market database.", color: @color_error}

	def market_embed(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy",
			color: @color_success,
			thumbnail: %Embed.Thumbnail{url: @icon_market},
			fields:
				Enum.map(items, fn item ->
					%{
						name: item.item,
						value:
							"💰 **B:** #{item.buy_price} | **S:** #{item.sell_price}\n📈 **Margin:** #{Float.round(item.margin * 100, 2)}%",
						inline: true
					}
				end),
			footer: %Embed.Footer{
				text: "EVE Market Scan • #{DateTime.utc_now() |> DateTime.to_date()}",
				icon_url: @icon_market
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
				# respond(intr, Messages.channel_registered(intr.channel_id))
				respond(intr, Messages.full_spec_embed())

			"remove_channel" ->
				# Discord.Database.delete(intr.guild_id)
				respond(intr, Messages.channel_removed(intr.channel_id))

			"list_channel" ->
				respond(intr, Messages.list_channel(nil))

			"check_market" ->
				# Api.Interaction.create_response(intr, %{type: 5})
				# items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)
				# Api.Interaction.edit_response(intr, %{embeds: [Messages.market_embed(items)]})
				respond(intr, Messages.market_embed([]))
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
		items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)

		if items != [] do
			embed = Messages.market_embed(items)

			Enum.each(Discord.Database.all(), fn record ->
				Api.Message.create(record.channel_id, embeds: [embed])
			end)
		end

		schedule_broadcast()
		{:noreply, state}
	end
end
