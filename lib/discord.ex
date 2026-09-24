defmodule Discord.Messages do
	alias Nostrum.Struct.Embed
	alias Nostrum.Struct.Interaction
	# alias Nostrum.Struct.Guild
	# alias Nostrum.Cache.GuildCache

	# use playwright to snap canvas images, it wont be that many

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	# @icon_ "https://images.evetech.net/types/52996/relic?size=64"
	# @icon_corporation "https://images.evetech.net/corporations/98666181/logo?size=64"

	@icon_ "https://images.evetech.net/types/81008/icon?size=64"
	@icon_elixir "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/elixir.png"
	@icon_market "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/background.png"
	@icon_database "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/database.png"

	# @icon_info "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/broadcast.png"
	@icon_error "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/failure.png"
	@icon_success "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/success.png"

	def get_canvas_graph do
		# canvas = Playwright.Page.query_selector(page, "canvas#my-canvas-id")
		# _png_binary = Playwright.ElementHandle.screenshot(canvas, %{type: "png"})
		# File.write!("captured_canvas.png", png_binary)
	end

	def format_margin do
	end

	def format_price do
	end

	def format_security_status do
	end

	def server_only(_interaction) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_error
			},
			title: "Server only",
			description: "This command can only be used inside a server, not in DMs.",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def error(_interaction) do
		%Embed{
			title: "Error",
			description: "Error",
			# url: "https://discord.com",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer - Error",
				url: "https://discord.com",
				icon_url: @icon_error
			},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def market_not_found_embed(item_name) do
		item_name = if is_binary(item_name), do: String.trim(item_name), else: ""
		item_name = if item_name == "", do: "that item", else: item_name

		%Embed{
			title: "Item not found",
			description: "No cached market order was found for **#{item_name}**.",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer - Market Lookup",
				url: "https://discord.com",
				icon_url: @icon_error
			},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	def market_list_embed(items) do
		lines = items |> Enum.with_index(1) |> Enum.map(fn {item, i} -> list_line(item, i) end)
		description = truncate_lines(lines, "")

		description =
			if description == "" do
				"No items are undercutting the Jita buy wall right now."
			else
				description
			end

		%Embed{
			title: "Items undercutting the Jita buy wall",
			description: description,
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer - Market List",
				url: "https://discord.com",
				icon_url: @icon_success
			},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			},
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	defp list_line(item, i) do
		name = item[:item] || "?"
		location = item[:location_name] || item[:system_name] || "?"

		"#{i}. **#{name}** — sell #{format_isk(item[:sell_price])} / buy #{format_isk(item[:buy_price])} | +#{format_isk(item[:margin])} ISK @ #{location}"
	end

	# Embed descriptions cap at 4096 chars; drop lines that would overflow.
	defp truncate_lines([], acc), do: acc

	defp truncate_lines([line | rest], acc) do
		next = if acc == "", do: line, else: acc <> "\n" <> line

		if String.length(next) < 4000 do
			truncate_lines(rest, next)
		else
			acc
		end
	end

	defp format_isk(nil), do: "?"
	defp format_isk(number), do: (number * 1.0) |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

	def market_embed(item) do
		market_url = "https://janice.e-351.com/i/#{item.type_id}/market/2"
		reference_url = "https://everef.net/types/#{item.type_id}"

		%Embed{
			title: item.item_name || "Market order",
			description: "
						[Market](#{market_url}) [Reference](#{reference_url})
						",
			# url: "https://discord.com",
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer - Market Order",
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
					name: "#{item.region_name}",
					value: "#{format_security(item.security_status)} #{item.system_name}",
					inline: true
				},
				profit_field(item)
			],
			footer: %Embed.Footer{
				text: "Sent with Elixir",
				icon_url: @icon_elixir
			}
		}
	end

	defp profit_field(item) do
		name =
			if is_nil(item.instant_sell_profit),
				do: "Sell price",
				else: "#{format_isk(item.instant_sell_profit)} ISK profit"

		%Embed.Field{
			name: name,
			value: "#{format_isk(item.price)} ISK",
			inline: true
		}
	end

	defp format_security(nil), do: "?"
	defp format_security(security), do: abs(Float.round(security * 1.0, 1))

	def add_channel(interaction) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_success
			},
			title: "Channel Registiration",
			description: "<##{interaction.channel_id}> is now registered for market alerts.",
			color: @color_success,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_database
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
				icon_url: @icon_success
			},
			title: "Channel Registiration",
			description: "<##{interaction.channel_id}> will no longer recieve market alerts.",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_database
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
				icon_url: @icon_success
			},
			title: "Channel Registiration",
			description: description,
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_database
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
	alias Nostrum.Constants.ApplicationCommandOptionType
	alias Nostrum.Struct.Interaction

	@admin_only "16"
	@interval 15 * 60 * 1000

	# integration_types: 0 = guild install (server), 1 = user install (personal)
	# contexts: 0 = guild, 1 = bot DMs, 2 = private channels
	@server_install [0]
	@server_context [0]
	@both_installs [0, 1]
	@any_context [0, 1, 2]

	defp schedule_broadcast, do: Process.send_after(self(), :broadcast, @interval)

	def handle_event({:READY, _, _}) do
		server_commands = [
			%{
				name: "add_channel",
				description: "Set current channel for alerts",
				integration_types: @server_install,
				contexts: @server_context,
				default_member_permissions: @admin_only
			},
			%{
				name: "remove_channel",
				description: "Remove alerts from this server",
				integration_types: @server_install,
				contexts: @server_context,
				default_member_permissions: @admin_only
			},
			%{
				name: "list_channel",
				description: "Show the current update channel",
				integration_types: @server_install,
				contexts: @server_context
			}
		]

		market_commands = [
			%{
				name: "check_market",
				description: "Check an item in the market",
				integration_types: @both_installs,
				contexts: @any_context,
				options: [
					%{
						type: ApplicationCommandOptionType.string(),
						name: "item",
						description: "EVE item name",
						required: true
					}
				]
			},
			%{
				name: "list_market",
				description: "Items undercutting the Jita buy wall",
				integration_types: @both_installs,
				contexts: @any_context
			}
		]

		Api.ApplicationCommand.bulk_overwrite_global_commands(server_commands ++ market_commands)
		schedule_broadcast()
	end

	def handle_event({:INTERACTION_CREATE, %Interaction{data: %{name: name}} = interaction, _}) do
		case name do
			"add_channel" ->
				if is_nil(interaction.guild_id) do
					respond(interaction, Messages.server_only(interaction))
				else
					Discord.Database.upsert(interaction.guild_id, interaction.channel_id)
					respond(interaction, Messages.add_channel(interaction))
				end

			"remove_channel" ->
				if is_nil(interaction.guild_id) do
					respond(interaction, Messages.server_only(interaction))
				else
					Discord.Database.delete(interaction.guild_id)
					respond(interaction, Messages.channel_removed(interaction))
				end

			"list_channel" ->
				if is_nil(interaction.guild_id) do
					respond(interaction, Messages.server_only(interaction))
				else
					channel_id = Discord.Database.get(interaction.guild_id)
					respond(interaction, Messages.list_channel(channel_id))
				end

			"check_market" ->
				item_name = option_value(interaction, "item")

				case Market.Database.get_market_item(item_name) do
					nil -> respond(interaction, Messages.market_not_found_embed(item_name))
					item -> respond(interaction, Messages.market_embed(item))
				end

			"list_market" ->
				items = Market.Database.get_items_less_than_jita_buy()
				respond(interaction, Messages.market_list_embed(items))
		end
	end

	def handle_event(_), do: :ok

	# --- Helpers ---

	defp option_value(%{data: %{options: options}}, name) when is_list(options) do
		Enum.find_value(options, fn
			%{name: ^name, value: value} -> value
			_ -> nil
		end)
	end

	defp option_value(_interaction, _name), do: nil

	defp respond(intr, %Nostrum.Struct.Embed{} = embed) do
		Api.Interaction.create_response(intr, %{
			type: 4,
			data: %{embeds: [embed]}
		})
	end

	def handle_info(:broadcast, state) do
		schedule_broadcast()
		{:noreply, state}
	end
end
