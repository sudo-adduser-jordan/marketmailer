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

	def market_disambiguation_embed(item_name, candidates) do
		searched = if is_binary(item_name), do: String.trim(item_name), else: ""
		searched = if searched == "", do: "that item", else: searched

		names =
			candidates
			|> List.wrap()
			|> Enum.map(&candidate_name/1)
			|> Enum.reject(&is_nil/1)
			|> Enum.map(&String.trim/1)
			|> Enum.reject(&(&1 == ""))
			|> Enum.uniq()
			|> Enum.take(10)

		lines = names |> Enum.with_index(1) |> Enum.map(fn {name, i} -> "#{i}. **#{name}**" end)
		list = truncate_lines(lines, "")

		description =
			if list == "" do
				"No cached market order was found for **#{searched}**."
			else
				"Multiple items match **#{searched}**:\n#{list}\n\nRe-run `/check_market` with the exact name."
			end

		%Embed{
			title: "Multiple items found",
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

	defp candidate_name(%{item_name: name}) when is_binary(name), do: name
	defp candidate_name(%{item: name}) when is_binary(name), do: name
	defp candidate_name(%{name: name}) when is_binary(name), do: name
	defp candidate_name(%{"item_name" => name}) when is_binary(name), do: name
	defp candidate_name(%{"item" => name}) when is_binary(name), do: name
	defp candidate_name(%{"name" => name}) when is_binary(name), do: name
	defp candidate_name(_), do: nil

	def market_list_embed(nil), do: market_list_embed([])

	def market_list_embed(items) when is_list(items) do
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

	def market_list_embed(_), do: market_list_embed([])

	defp list_field(item, atom_key, string_key) do
		atom_val = if is_map(item), do: Map.get(item, atom_key)
		if atom_val == nil, do: if(is_map(item), do: Map.get(item, string_key)), else: atom_val
	end

	defp list_line(item, i) do
		name = list_field(item, :item, "item") || "?"
		location = list_field(item, :location_name, "location_name") || list_field(item, :system_name, "system_name") || "?"

		"#{i}. **#{name}** — sell #{format_isk(list_field(item, :sell_price, "sell_price"))} / buy #{format_isk(list_field(item, :buy_price, "buy_price"))} | +#{format_isk(list_field(item, :margin, "margin"))} ISK @ #{location}"
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

	defp format_isk(number) when is_number(number),
		do: (number * 1.0) |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

	defp format_isk(binary) when is_binary(binary) do
		case Float.parse(String.trim(binary)) do
			{number, _} -> format_isk(number)
			:error -> "?"
		end
	end

	defp format_isk(_), do: "?"

	# ANSI code-block colors (Discord only renders color inside code blocks).
	@ansi_reset "\e[0m"
	@ansi_green "\e[32m"
	@ansi_yellow "\e[33m"
	@ansi_red "\e[31m"
	@ansi_gray "\e[90m"

	defp ansi_block(color, text), do: "```ansi\n#{color}#{text}#{@ansi_reset}\n```"

	# Highsec green, lowsec yellow, nullsec red, unknown gray.
	defp security_color(nil), do: @ansi_gray
	defp security_color(""), do: @ansi_gray

	defp security_color(security) when is_binary(security) do
		case Float.parse(String.trim(security)) do
			{number, _} -> security_color(number)
			:error -> @ansi_gray
		end
	end

	defp security_color(security) when is_number(security) do
		cond do
			security >= 0.5 -> @ansi_green
			security >= 0.0 -> @ansi_yellow
			true -> @ansi_red
		end
	end

	defp security_color(_), do: @ansi_gray

	defp location_value(item) do
		text =
			"#{or_unknown(item.location_name)} - #{or_unknown(item.system_name)} - #{or_unknown(item.region_name)} (#{format_security(item.security_status)})"

		ansi_block(security_color(item.security_status), text)
	end

	defp price_value(nil), do: ansi_block(@ansi_gray, "? ISK")
	defp price_value(price), do: ansi_block(@ansi_green, "#{format_isk(price)} ISK")

	def market_embed(item, thumbnail_url \\ nil, image_url \\ nil) do
		janice_url = "https://janice.e-351.com/i/#{item.type_id}/market/2"
		eve_ref_url = "https://everef.net/types/#{item.type_id}"
		eve_tycoon_url = "https://evetycoon.com/market/#{item.type_id}"
		# Per-item icon from the EVE image server; Discord loads it, so the
		# lookup stays a single instant DB query with no capture/fetch.
		type_icon = "https://images.evetech.net/types/#{item.type_id}/icon?size=64"

		%Embed{
			title: item.item_name || "Market order",
			description: "
						[Janice](#{janice_url}) [Eve Ref](#{eve_ref_url}) [Eve Tycoon](#{eve_tycoon_url})
						",
			# url: "https://discord.com",
			color: embed_color(item.instant_sell_profit),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: thumbnail_url || type_icon
			},
			image: %Embed.Image{
				url: image_url || @icon_market
			},
			fields: [
				%Embed.Field{
					name: "Location",
					value: location_value(item),
					inline: false
				},
				%Embed.Field{
					name: "Sell",
					value: price_value(item.price),
					inline: true
				},
				%Embed.Field{
					name: "Buy",
					value: price_value(item.buy_price),
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

	# ANSI blocks render green/red/gray text in Discord.
	defp margin_value(nil), do: ansi_block(@ansi_gray, "? ISK")

	defp margin_value(profit) when is_number(profit) do
		sign = if profit >= 0, do: "+", else: "-"
		color = if profit >= 0, do: @ansi_green, else: @ansi_red
		ansi_block(color, "#{sign}#{format_isk(abs(profit))} ISK")
	end

	defp margin_value(_), do: ansi_block(@ansi_gray, "? ISK")

	defp or_unknown(nil), do: "?"
	defp or_unknown(""), do: "?"
	defp or_unknown(value), do: value

	defp format_security(nil), do: "?"
	defp format_security(""), do: "?"

	defp format_security(security) when is_binary(security) do
		case Float.parse(String.trim(security)) do
			{number, _} -> format_security(number)
			:error -> "?"
		end
	end

	defp format_security(security) when is_number(security), do: Float.round(security * 1.0, 1)
	defp format_security(_), do: "?"

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
				candidates = safe_suggest_items(item_name, 10)

				# Instant DB-only lookup: single SELECT, no ESI/Janice, so the
				# direct reply stays inside Discord's 3s window. Found and
				# not-found both answer immediately with no thinking state.
				# The Janice chart follows as an async edit (with the failure
				# image as fallback) so a slow capture never blocks the reply.
				# Free text is always accepted; an inexact multi-match replies
				# with the candidate list instead of a possibly wrong detail.
				case safe_get_market_item(item_name) do
					nil ->
						reply_for_missing_item(interaction, item_name, candidates)

					item ->
						if exact_item_match?(item_name, item, candidates) or length(candidates) <= 1 do
							reply_with_detail(interaction, item)
						else
							respond(interaction, Messages.market_disambiguation_embed(item_name, candidates))
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

						try do
							case Api.Interaction.create_response(interaction, response) do
								:ok -> start_list_task(bot_name, interaction)
								{:ok, _} -> start_list_task(bot_name, interaction)
								{:error, reason} -> list_defer_fallback(interaction, reason)
							end
						rescue
							error ->
								list_defer_fallback(interaction, Exception.message(error))
						catch
							_, reason -> list_defer_fallback(interaction, reason)
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

	defp safe_suggest_items(item_name, limit) when is_binary(item_name) and is_integer(limit) do
		case Market.Database.suggest_items(item_name, limit) do
			items when is_list(items) -> items
			_ -> []
		end
	rescue
		_ -> []
	catch
		_, _ -> []
	end

	defp safe_suggest_items(_item_name, _limit), do: []

	defp reply_with_detail(interaction, item) do
		respond(interaction, Messages.market_embed(item))

		case active_bot_name() do
			nil -> :ok
			bot_name -> start_chart_task(bot_name, interaction, item)
		end
	end

	# No direct row: a single candidate resolves to its detail, several
	# become the disambiguation list, none stays the not-found embed.
	defp reply_for_missing_item(interaction, item_name, [single]) do
		case safe_get_market_item(candidate_name(single)) do
			nil -> respond(interaction, Messages.market_disambiguation_embed(item_name, [single]))
			item -> reply_with_detail(interaction, item)
		end
	end

	defp reply_for_missing_item(interaction, item_name, candidates) do
		if is_list(candidates) and candidates != [] do
			respond(interaction, Messages.market_disambiguation_embed(item_name, candidates))
		else
			respond(interaction, Messages.market_not_found_embed(item_name))
		end
	end

	defp candidate_name(%{item_name: name}) when is_binary(name), do: name
	defp candidate_name(%{item: name}) when is_binary(name), do: name
	defp candidate_name(%{name: name}) when is_binary(name), do: name
	defp candidate_name(%{"item_name" => name}) when is_binary(name), do: name
	defp candidate_name(%{"item" => name}) when is_binary(name), do: name
	defp candidate_name(%{"name" => name}) when is_binary(name), do: name
	defp candidate_name(_), do: nil

	defp exact_item_match?(input, item, candidates) do
		normalize_item(input) != "" and
			(normalize_item(input) == normalize_item(item.item_name) or
				 Enum.any?(candidates, fn candidate -> normalize_item(input) == normalize_item(candidate_name(candidate)) end))
	end

	defp normalize_item(name) when is_binary(name) do
		name |> String.trim() |> String.replace(~r/\s+/, " ") |> String.trim() |> String.downcase()
	end

	defp normalize_item(_), do: ""

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
				run_list_task(bot_name, interaction)
			end)

		case task do
			{:ok, _pid} ->
				:ok

			{:error, reason} ->
				log_discord_warning("list_market_task_failed", reason, interaction)
				try_edit_empty_list(bot_name, interaction)
		end
	rescue
		error ->
			log_discord_warning("list_market_task_failed", Exception.message(error), interaction)
			try_edit_empty_list(bot_name, interaction)
	catch
		_, reason ->
			log_discord_warning("list_market_task_failed", reason, interaction)
			try_edit_empty_list(bot_name, interaction)
	end

	# The deferred task must never die silently (Discord would leave the
	# interaction on "thinking..." then "interaction failed"): any lookup,
	# render, or edit crash still produces the empty-list embed.
	defp run_list_task(bot_name, interaction) do
		embed =
			try do
				Messages.market_list_embed(safe_get_items())
			rescue
				_ -> Messages.market_list_embed([])
			catch
				_, _ -> Messages.market_list_embed([])
			end

		edit_response(bot_name, interaction, %{embeds: [embed]})
	rescue
		_ ->
			try_edit_empty_list(bot_name, interaction)
	catch
		_, _ -> try_edit_empty_list(bot_name, interaction)
	end

	defp try_edit_empty_list(bot_name, interaction) do
		edit_response(bot_name, interaction, %{embeds: [Messages.market_list_embed([])]})
	rescue
		error -> log_discord_warning("list_market_fallback_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("list_market_fallback_failed", reason, interaction)
	end

	defp list_defer_fallback(interaction, reason) do
		log_discord_warning("list_market_defer_failed", reason, interaction)

		try do
			respond(interaction, Messages.market_list_embed(safe_get_items()))
		rescue
			error -> log_discord_warning("list_market_defer_fallback_failed", Exception.message(error), interaction)
		catch
			_, fallback_reason -> log_discord_warning("list_market_defer_fallback_failed", fallback_reason, interaction)
		end
	end

	# Never let a DB/ESI failure crash the interaction handler with no
	# response: log once and fall back to the empty list embed.
	defp safe_get_items do
		case Market.Database.get_items_less_than_jita_buy() do
			items when is_list(items) -> items
			_ -> []
		end
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
		Bot.with_bot(bot_name, fn -> Api.Interaction.edit_response(interaction, payload) end)
		|> case do
			:ok -> :ok
			{:ok, _message} -> :ok
			{:error, reason} -> log_discord_warning("check_market_edit_failed", reason, interaction)
			other -> log_discord_warning("check_market_edit_failed", other, interaction)
		end
	rescue
		error -> log_discord_warning("check_market_edit_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("check_market_edit_failed", reason, interaction)
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
