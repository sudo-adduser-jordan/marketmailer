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
	@icon_market "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/background.png"
	@icon_database "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/database.png"

	# @icon_info "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/broadcast.png"
	@icon_error "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/failure.png"
	@icon_success "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/success.png"

	# Version badge — SemVer from mix.exs, read at runtime so Castle hot
	# upgrades show the new version without a restart.
	defp with_version(%Embed{} = embed) do
		%{embed | footer: %Embed.Footer{text: "Marketmailer v#{app_version()}"}}
	end

	defp app_version do
		case Application.spec(:marketmailer, :vsn) do
			nil -> Mix.Project.config()[:version] || "0.0.0"
			vsn when is_list(vsn) -> List.to_string(vsn)
			vsn when is_binary(vsn) -> vsn
			_ -> Mix.Project.config()[:version] || "0.0.0"
		end
	end

	def get_canvas_graph(type_id, opts \\ []), do: Janice.Capture.capture(type_id, opts)

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
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
		}
		|> with_version()
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
			}
		}
		|> with_version()
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
			}
		}
		|> with_version()
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
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_success
			},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			}
		}
		|> with_version()
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

	def market_embed(item, thumbnail_url \\ nil, image_url \\ nil) do
		market_url = "https://janice.e-351.com/i/#{item.type_id}/market/2"
		reference_url = "https://everef.net/types/#{item.type_id}"
		# Per-item icon from the EVE image server; Discord loads it, so the
		# lookup stays a single instant DB query with no capture/fetch.
		type_icon = "https://images.evetech.net/types/#{item.type_id}/icon?size=64"

		%Embed{
			title: item.item_name || "Market order",
			description: "
						[Market](#{market_url}) [Reference](#{reference_url})
						",
			# url: "https://discord.com",
			color: embed_color(item.instant_sell_profit),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{
				name: "Marketmailer - Market Order",
				url: "https://discord.com",
				icon_url: @icon_success
			},
			thumbnail: %Embed.Thumbnail{
				url: thumbnail_url || type_icon
			},
			image: %Embed.Image{
				url: image_url || @icon_market
			},
			fields: [
				%Embed.Field{
					name: "Location",
					value:
						"#{or_unknown(item.region_name)} - #{or_unknown(item.system_name)} - #{or_unknown(item.location_name)} (#{format_security(item.security_status)})",
					inline: false
				},
				%Embed.Field{
					name: "Sell",
					value: "#{format_isk(item.price)} ISK",
					inline: true
				},
				%Embed.Field{
					name: "Buy",
					value: "#{format_isk(item.buy_price)} ISK",
					inline: true
				},
				%Embed.Field{
					name: "Margin",
					value: margin_value(item.instant_sell_profit),
					inline: false
				}
			]
		}
		|> with_version()
	end

	# Green sidebar on profit, red on loss, neutral when unknown.
	defp embed_color(nil), do: @color_info
	defp embed_color(profit) when is_number(profit) and profit > 0, do: @color_success
	defp embed_color(_profit), do: @color_error

	# Discord has no colored text; diff blocks render +/- lines green/red.
	defp margin_value(nil), do: "```diff\n? ISK\n```"

	defp margin_value(profit) when is_number(profit) do
		sign = if profit >= 0, do: "+", else: "-"
		"```diff\n#{sign}#{format_isk(abs(profit))} ISK\n```"
	end

	defp or_unknown(nil), do: "?"
	defp or_unknown(""), do: "?"
	defp or_unknown(value), do: value

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
			}
		}
		|> with_version()
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
			}
		}
		|> with_version()
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
			}
		}
		|> with_version()
	end
end

defmodule Discord.Consumer do
	@behaviour Nostrum.Consumer

	alias Discord.Messages
	alias Nostrum.Api
	alias Nostrum.Bot
	alias Nostrum.Constants.ApplicationCommandOptionType
	alias Nostrum.Constants.InteractionCallbackType
	alias Nostrum.Struct.Interaction

	@admin_only "16"

	# integration_types: 0 = guild install (server), 1 = user install (personal)
	# contexts: 0 = guild, 1 = bot DMs, 2 = private channels
	@server_install [0]
	@server_context [0]
	@both_installs [0, 1]
	@any_context [0, 1, 2]

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
						required: true,
						autocomplete: true
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
	end

	# Autocomplete must come before the command clause below: autocomplete
	# interactions carry the same command name in data.
	def handle_event({:INTERACTION_CREATE, %Interaction{type: 4, data: %{name: "check_market"}} = interaction, _}) do
		partial = focused_option_value(interaction, "item")

		choices =
			for %{item_name: name} <- Market.Database.suggest_items(partial || ""),
					do: %{name: name, value: name}

		Api.Interaction.create_response(interaction, %{
			type: InteractionCallbackType.application_command_autocomplete_result(),
			data: %{choices: Enum.take(choices, 25)}
		})
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

				# Instant DB-only lookup: single SELECT, no ESI/Janice, so the
				# direct reply stays inside Discord's 3s window. Found and
				# not-found both answer immediately with no thinking state.
				# The Janice chart follows as an async edit (with the failure
				# image as fallback) so a slow capture never blocks the reply.
				case safe_get_market_item(item_name) do
					nil ->
						respond(interaction, Messages.market_not_found_embed(item_name))

					item ->
						respond(interaction, Messages.market_embed(item))

						case active_bot_name() do
							nil -> :ok
							bot_name -> start_chart_task(bot_name, interaction, item)
						end
				end

			"list_market" ->
				case active_bot_name() do
					# No bot runtime (tests, dev shell): synchronous immediate reply.
					nil ->
						respond(interaction, Messages.market_list_embed(safe_get_items()))

					# Same 3s-ack rationale as check_market: the list query
					# also backfills names/systems over synchronous ESI.
					bot_name ->
						response = %{
							type: InteractionCallbackType.deferred_channel_message_with_source()
						}

						case Api.Interaction.create_response(interaction, response) do
							:ok -> start_list_task(bot_name, interaction)
							{:error, reason} -> log_discord_warning("list_market_defer_failed", reason, interaction)
						end
				end
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

	# The partially typed value of the focused autocomplete option.
	defp focused_option_value(%{data: %{options: options}}, name) when is_list(options) do
		Enum.find_value(options, fn
			%{name: ^name, value: value} -> value
			_ -> nil
		end)
	end

	defp focused_option_value(_interaction, _name), do: nil

	defp safe_get_market_item(item_name) do
		Market.Database.get_market_item(item_name)
	rescue
		error ->
			Marketmailer.Log.warning(
				"check_market_lookup_failed",
				%{reason: Exception.message(error)},
				"check_market lookup failed; replying not-found"
			)

			nil
	catch
		_, reason ->
			Marketmailer.Log.warning(
				"check_market_lookup_failed",
				%{reason: inspect(reason)},
				"check_market lookup failed; replying not-found"
			)

			nil
	end

	# Janice chart follows the instant reply as an async edit: success
	# attaches the captured chart, failure attaches the bundled failure
	# image so the embed always ends with a graph. Never blocks check_market.
	defp start_chart_task(bot_name, interaction, item) do
		task =
			Task.Supervisor.start_child(Marketmailer.TaskSup, fn ->
				capture_and_edit(bot_name, interaction, item)
			end)

		case task do
			{:ok, _pid} ->
				:ok

			{:error, reason} ->
				log_discord_warning("check_market_chart_task_failed", reason, interaction)
		end
	end

	defp capture_and_edit(bot_name, interaction, item) do
		case Janice.Capture.capture(item.type_id) do
			{:ok, png} ->
				filename = Janice.Capture.filename(item.type_id)
				embed = Messages.market_embed(item, nil, "attachment://#{filename}")
				edit_response(bot_name, interaction, %{embeds: [embed], files: [%{name: filename, body: png}]})

			{:error, reason} ->
				Marketmailer.Log.warning(
					"janice_capture_failed",
					%{type_id: item.type_id, reason: inspect(reason)},
					"Janice chart capture failed; using the fallback chart image"
				)

				edit_fallback_response(bot_name, interaction, item)
		end
	end

	defp edit_fallback_response(bot_name, interaction, item) do
		filename = Janice.Capture.fallback_filename()
		embed = Messages.market_embed(item, nil, "attachment://#{filename}")

		edit_response(bot_name, interaction, %{
			embeds: [embed],
			files: [%{name: filename, body: Janice.Capture.fallback_image()}]
		})
	rescue
		_ -> edit_response(bot_name, interaction, %{embeds: [Messages.market_embed(item)]})
	end

	defp start_list_task(bot_name, interaction) do
		task =
			Task.Supervisor.start_child(Marketmailer.TaskSup, fn ->
				edit_response(bot_name, interaction, %{embeds: [Messages.market_list_embed(safe_get_items())]})
			end)

		case task do
			{:ok, _pid} ->
				:ok

			{:error, reason} ->
				log_discord_warning("list_market_task_failed", reason, interaction)
				edit_response(bot_name, interaction, %{embeds: [Messages.market_list_embed([])]})
		end
	end

	# Never let a DB/ESI failure crash the interaction handler with no
	# response: log once and fall back to the empty list embed.
	defp safe_get_items do
		Market.Database.get_items_less_than_jita_buy()
	rescue
		error ->
			Marketmailer.Log.warning(
				"list_market_lookup_failed",
				%{reason: Exception.message(error)},
				"list_market lookup failed; replying empty list"
			)

			[]
	catch
		_, reason ->
			Marketmailer.Log.warning(
				"list_market_lookup_failed",
				%{reason: inspect(reason)},
				"list_market lookup failed; replying empty list"
			)

			[]
	end

	defp edit_response(bot_name, interaction, payload) do
		case Bot.with_bot(bot_name, fn -> Api.Interaction.edit_response(interaction, payload) end) do
			:ok -> :ok
			{:ok, _message} -> :ok
			{:error, reason} -> log_discord_warning("check_market_edit_failed", reason, interaction)
		end
	end

	defp active_bot_name do
		case Bot.fetch_all_bots() do
			[%{name: name}] -> name
			_ -> nil
		end
	end

	defp log_discord_warning(event, reason, interaction) do
		Marketmailer.Log.warning(
			event,
			%{interaction_id: interaction.id, reason: inspect(reason)},
			"Discord market response failed"
		)
	end

	defp respond(intr, %Nostrum.Struct.Embed{} = embed) do
		Api.Interaction.create_response(intr, %{
			type: 4,
			data: %{embeds: [embed]}
		})
	end
end
