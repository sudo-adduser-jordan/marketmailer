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

	# Footer carries both date and version — date left, version right,
	# joined with a middle dot so Discord renders a single footer line.
	defp with_version(%Embed{timestamp: ts} = embed) do
		date = ts || DateTime.utc_now() |> DateTime.to_iso8601()

		%{embed | footer: %Embed.Footer{text: "#{date} • v#{app_version()}"}, timestamp: nil}
	end

	defp app_version do
		case Application.spec(:marketmailer, :vsn) do
			nil -> Mix.Project.config()[:version] || "0.0.0"
			vsn when is_list(vsn) -> List.to_string(vsn)
			vsn when is_binary(vsn) -> vsn
			_ -> Mix.Project.config()[:version] || "0.0.0"
		end
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

	# Accepts maps or string-keyed maps; shared with Discord.Consumer.
	def candidate_name(%{item_name: name}) when is_binary(name), do: name
	def candidate_name(%{item: name}) when is_binary(name), do: name
	def candidate_name(%{name: name}) when is_binary(name), do: name
	def candidate_name(%{"item_name" => name}) when is_binary(name), do: name
	def candidate_name(%{"item" => name}) when is_binary(name), do: name
	def candidate_name(%{"name" => name}) when is_binary(name), do: name
	def candidate_name(_), do: nil

	# Discord-only safety cap on how many undercut rows get rendered.
	@list_max 100

	# Cap, validate, and clamp once so the rendered page and the page
	# buttons can never disagree. Shared by market_list_embed/3 and
	# market_list_payload/3.
	defp paginate(items, page, per_page) do
		list = Enum.take(items, @list_max)
		per_page = if is_integer(per_page) and per_page > 0, do: per_page, else: list_per_page()
		page = clamp_page(page, max(1, ceil_div(length(list), per_page)))

		{list, page, per_page}
	end

	def market_list_embed(items, page \\ 1, per_page \\ 10)

	def market_list_embed(nil, _page, _per_page), do: market_list_embed([], 1, 10)

	def market_list_embed(items, page, per_page) when is_list(items) do
		{capped, page, per_page} = paginate(items, page, per_page)
		page_items = list_page_slice(capped, page, per_page)
		offset = (page - 1) * per_page

		lines =
			page_items
			|> Enum.with_index(offset + 1)
			|> Enum.map(fn {item, i} -> list_line(item, i) end)

		description =
			if page_items == [] do
				"No items are undercutting the Jita buy wall right now."
			else
				truncate_lines(lines, "")
			end

		total_pages = max(1, ceil_div(length(capped), per_page))

		title =
			if total_pages > 1 do
				"Items undercutting the Jita buy wall (#{page}/#{total_pages})"
			else
				"Items undercutting the Jita buy wall"
			end

		%Embed{
			title: title,
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

	def market_list_embed(_items, _page, _per_page), do: market_list_embed([], 1, 10)

	# Paginated payload: page-1 embed plus Prev/Next buttons. Empty lists
	# carry no components.
	def market_list_payload(items, page \\ 1, per_page \\ 10) do
		items = if is_list(items), do: items, else: []
		{list, page, per_page} = paginate(items, page, per_page)
		total_pages = max(1, ceil_div(length(list), per_page))

		%{embeds: [market_list_embed(list, page, per_page)], components: list_components(page, total_pages, length(list))}
	end

	def list_per_page, do: 10

	def list_components(_page, _total_pages, 0), do: []

	def list_components(_page, total_pages, _count) when total_pages <= 1, do: []

	def list_components(page, total_pages, _count) do
		[
			%{
				type: 1,
				components: [
					%{
						type: 2,
						style: 2,
						label: "Prev",
						custom_id: "market_list:page:#{page - 1}",
						disabled: page <= 1
					},
					%{
						type: 2,
						style: 2,
						label: "Next",
						custom_id: "market_list:page:#{page + 1}",
						disabled: page >= total_pages
					}
				]
			}
		]
	end

	defp clamp_page(page, total_pages) when is_integer(page), do: page |> max(1) |> min(total_pages)

	defp clamp_page(page, total_pages) when is_binary(page) do
		case Integer.parse(String.trim(page)) do
			{number, _} -> clamp_page(number, total_pages)
			:error -> 1
		end
	end

	defp clamp_page(_, _), do: 1

	defp ceil_div(0, _), do: 1
	defp ceil_div(count, per_page), do: div(count + per_page - 1, per_page)

	defp list_page_slice(items, page, per_page) do
		items |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
	end

	defp list_field(item, atom_key, string_key) do
		atom_val = if is_map(item), do: Map.get(item, atom_key)
		if atom_val == nil, do: if(is_map(item), do: Map.get(item, string_key)), else: atom_val
	end

	# Short mobile-width truncation with an ellipsis marker.
	# Plain (non-monospace) rows: no padding, each row wraps naturally.
	@list_item_width 18
	@list_system_width 10

	defp list_line(item, i) do
		name = list_truncate(list_field(item, :item, "item") || list_field(item, :item_name, "item_name"), @list_item_width)
		margin = format_list_margin(list_field(item, :margin, "margin"))
		system = list_truncate(list_field(item, :system_name, "system_name"), @list_system_width)
		security = format_security(list_field(item, :security_status, "security_status")) |> to_string()

		"#{i}. #{sec_emoji(list_field(item, :security_status, "security_status"))} **#{name}** — #{margin} • #{system} (#{security})"
	end

	defp list_truncate(nil, _max), do: "?"
	defp list_truncate("", _max), do: "?"

	defp list_truncate(name, max) when is_binary(name) and is_integer(max) do
		name = String.trim(name)

		cond do
			name == "" -> "?"
			String.length(name) <= max -> name
			true -> String.slice(name, 0, max - 1) <> "…"
		end
	end

	defp list_truncate(_, _), do: "?"

	# Compact margin without any pipe divider: +1.2k, +3.4M, +12.50.
	defp format_list_margin(nil), do: "?"

	defp format_list_margin(margin) when is_binary(margin) do
		case Float.parse(String.trim(margin)) do
			{number, _} -> format_list_margin(number)
			:error -> "?"
		end
	end

	defp format_list_margin(margin) when is_number(margin) do
		sign = if margin < 0, do: "-", else: "+"
		abs_value = abs(margin * 1.0)

		cond do
			abs_value >= 1_000_000 -> "#{sign}#{Float.round(abs_value / 1_000_000, 1)}M"
			abs_value >= 1_000 -> "#{sign}#{Float.round(abs_value / 1_000, 1)}k"
			true -> "#{sign}#{:erlang.float_to_binary(Float.round(abs_value, 2), decimals: 2)}"
		end
	end

	defp format_list_margin(_), do: "?"

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

	# Mobile-friendly security signal: plain emoji, no ANSI code blocks.
	# Highsec green, lowsec yellow, nullsec red, unknown white.
	defp sec_emoji(nil), do: "⚪"
	defp sec_emoji(""), do: "⚪"

	defp sec_emoji(security) when is_binary(security) do
		case Float.parse(String.trim(security)) do
			{number, _} -> sec_emoji(number)
			:error -> "⚪"
		end
	end

	defp sec_emoji(security) when is_number(security) do
		cond do
			security >= 0.5 -> "🟢"
			security >= 0.0 -> "🟡"
			true -> "🔴"
		end
	end

	defp sec_emoji(_), do: "⚪"

	defp location_value(item) do
		"#{sec_emoji(item.security_status)} #{or_unknown(item.location_name)} - #{or_unknown(item.system_name)} - #{or_unknown(item.region_name)} (#{format_security(item.security_status)})"
	end

	defp price_value(nil), do: "? ISK"
	defp price_value(price), do: "#{format_isk(price)} ISK"

	def market_embed(item, thumbnail_url \\ nil, image_url \\ nil) do
		janice_url = "https://janice.e-351.com/i/#{item.type_id}/market/2"
		eve_ref_url = "https://everef.net/types/#{item.type_id}"
		eve_tycoon_url = "https://evetycoon.com/market/#{item.type_id}"
		# Per-item icon from the EVE image server; Discord loads it, so the
		# lookup stays a single instant DB query with no capture/fetch.
		type_icon = "https://images.evetech.net/types/#{item.type_id}/icon?size=64"

		%Embed{
			title: item.item_name || "Market order",
			description: "[Janice](#{janice_url})\n[Eve Ref](#{eve_ref_url})\n[Eve Tycoon](#{eve_tycoon_url})",
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

	# Plain margin text with an emoji signal (no code block).
	defp margin_value(nil), do: "⚪ ? ISK"

	defp margin_value(profit) when is_number(profit) do
		sign = if profit >= 0, do: "+", else: "-"
		emoji = if profit >= 0, do: "🟢", else: "🔴"
		"#{emoji} #{sign}#{format_isk(abs(profit))} ISK"
	end

	defp margin_value(_), do: "⚪ ? ISK"

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

	# add/remove/list differ only in description and color, so they share
	# one embed skeleton.
	defp channel_embed(description, color) do
		%Embed{
			author: %Embed.Author{
				name: "Marketmailer",
				url: "https://discord.com",
				icon_url: @icon_success
			},
			title: "Channel Registration",
			description: description,
			color: color,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_database
			}
		}
		|> with_version()
	end

	def add_channel(interaction) do
		channel_embed("<##{interaction.channel_id}> is now registered for market alerts.", @color_success)
	end

	def channel_removed(interaction) do
		channel_embed("<##{interaction.channel_id}> will no longer receive market alerts.", @color_error)
	end

	def list_channel(record) do
		channel_id = if record, do: record.channel_id

		description =
			if channel_id do
				"<##{channel_id}> is registered to receive market alerts."
			else
				"No channel has been registered for this server yet."
			end

		channel_embed(description, @color_info)
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

	def handle_event(
				{:INTERACTION_CREATE, %Interaction{type: 3, data: %{custom_id: "market_list:page:" <> _}} = interaction, _}
			) do
		page = list_page_from_custom_id(interaction)
		payload = Messages.market_list_payload(safe_get_items(), page, Messages.list_per_page())

		Api.Interaction.create_response(interaction, %{
			type: InteractionCallbackType.update_message(),
			data: payload
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
						respond(interaction, Messages.market_list_payload(safe_get_items(), 1, Messages.list_per_page()))

					# Deferred ack first: the list query scans the full
					# undercut view, so it runs in the async task below.
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

	# Candidate name lookup and normalization live in
	# `Discord.Messages` / `Market.Database` so the consumer and the
	# embed layer always agree.
	defp candidate_name(candidate), do: Messages.candidate_name(candidate)

	defp exact_item_match?(input, item, candidates) do
		normalize_item(input) != "" and
			(normalize_item(input) == normalize_item(item.item_name) or
				 Enum.any?(candidates, fn candidate -> normalize_item(input) == normalize_item(candidate_name(candidate)) end))
	end

	defp normalize_item(name) when is_binary(name), do: Market.Database.normalize_item_name(name)

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
		payload =
			try do
				Messages.market_list_payload(safe_get_items(), 1, Messages.list_per_page())
			rescue
				_ -> Messages.market_list_payload([], 1, Messages.list_per_page())
			catch
				_, _ -> Messages.market_list_payload([], 1, Messages.list_per_page())
			end

		edit_response(bot_name, interaction, payload)
	rescue
		_ ->
			try_edit_empty_list(bot_name, interaction)
	catch
		_, _ -> try_edit_empty_list(bot_name, interaction)
	end

	defp try_edit_empty_list(bot_name, interaction) do
		edit_response(bot_name, interaction, Messages.market_list_payload([], 1, Messages.list_per_page()))
	rescue
		error -> log_discord_warning("list_market_fallback_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("list_market_fallback_failed", reason, interaction)
	end

	defp list_defer_fallback(interaction, reason) do
		log_discord_warning("list_market_defer_failed", reason, interaction)

		try do
			respond(interaction, Messages.market_list_payload(safe_get_items(), 1, Messages.list_per_page()))
		rescue
			error -> log_discord_warning("list_market_defer_fallback_failed", Exception.message(error), interaction)
		catch
			_, fallback_reason -> log_discord_warning("list_market_defer_fallback_failed", fallback_reason, interaction)
		end
	end

	defp list_page_from_custom_id(%{data: %{custom_id: "market_list:page:" <> page}}) do
		case Integer.parse(String.trim(page)) do
			{number, _} -> max(number, 1)
			:error -> 1
		end
	end

	defp list_page_from_custom_id(_), do: 1

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

	defp respond(intr, %{embeds: embeds, components: components}) do
		Api.Interaction.create_response(intr, %{
			type: 4,
			data: %{embeds: embeds, components: components}
		})
	end
end

defmodule Discord.Broadcaster do
	@moduledoc """
	Listens for completed market refreshes and broadcasts the undercut list
	to registered channels. Failed refreshes are log-only (each RegionManager
	already emits a `region_refresh_failed` warning to `logs/errors.jsonl`);
	nothing is sent to Discord for them so one flaky page cannot spam every
	channel.
	"""

	use GenServer

	alias Discord.Database, as: DiscordDatabase
	alias Discord.Messages
	alias Marketmailer.RegionManager
	alias Nostrum.Api
	alias Nostrum.Bot

	@seen_limit 10_000

	def start_link(opts \\ []) do
		name = Keyword.get(opts, :name, __MODULE__)
		GenServer.start_link(__MODULE__, opts, name: name)
	end

	@impl true
	def init(opts) do
		regions = Keyword.get(opts, :regions, Marketmailer.RegionManagerSupervisor.region_ids())
		Enum.each(regions, &subscribe_region/1)

		{:ok,
		 %{
			 async: Keyword.get(opts, :async, true),
			 task_supervisor: Keyword.get(opts, :task_supervisor, Marketmailer.TaskSup),
			 channels_fun: Keyword.get(opts, :channels_fun, &DiscordDatabase.registered_channels/0),
			 market_fun: Keyword.get(opts, :market_fun, &Market.Database.get_items_less_than_jita_buy/0),
			 deliver_fun: Keyword.get(opts, :deliver_fun, &deliver/2),
			 prune_fun: Keyword.get(opts, :prune_fun, &DiscordDatabase.delete_by_channel/1),
			 pending: MapSet.new(),
			 seen: MapSet.new()
		 }}
	end

	@impl true
	def handle_info({:region_refresh_complete, summary}, state) do
		start_refresh(summary, state)
	end

	# Failures are intentionally log-only: each RegionManager already logs
	# `region_refresh_failed`. Sending an embed per failed cycle spammed
	# every registered channel on transient 429/503/timeouts and on every
	# 10-minute cycle_timeout.
	def handle_info({:region_refresh_failed, _summary}, state) do
		{:noreply, state}
	end

	def handle_info({:broadcast_done, key, result}, state) do
		{:noreply, complete_refresh(state, key, result)}
	end

	def handle_info(_message, state), do: {:noreply, state}

	@impl true
	def handle_cast(message, state), do: handle_info(message, state)

	# RegionManagers boot before the broadcaster in prod, but a restarted
	# manager or broadcaster must still find each other: managers auto-attach
	# the default broadcaster on init, and missing regions here are simply
	# skipped (their manager attaches us when it boots).
	defp subscribe_region(region) do
		RegionManager.subscribe(region, self())
		:ok
	catch
		:exit, _ -> :ok
	end

	defp start_refresh(summary, state) do
		key = {Map.get(summary, :region), Map.get(summary, :cycle_id)}

		if MapSet.member?(state.pending, key) or MapSet.member?(state.seen, key) do
			{:noreply, state}
		else
			state = %{state | pending: MapSet.put(state.pending, key)}

			if state.async do
				start_async_refresh(state, key, summary)
			else
				result = safely_process_refresh(summary, state)
				{:noreply, complete_refresh(state, key, result)}
			end
		end
	end

	defp start_async_refresh(state, key, summary) do
		owner = self()

		case Task.Supervisor.start_child(state.task_supervisor, fn ->
					 result = safely_process_refresh(summary, state)
					 send(owner, {:broadcast_done, key, result})
				 end) do
			{:ok, _pid} ->
				{:noreply, state}

			{:error, reason} ->
				log_broadcast_failure("broadcast_task_failed", reason)
				{:noreply, remember(state, key)}
		end
	end

	defp complete_refresh(state, key, result) do
		state = remember(state, key)

		case result do
			:ok ->
				state

			{:ok, _value} ->
				state

			{:error, reason} ->
				log_broadcast_failure("broadcast_failed", reason)
				state
		end
	end

	defp remember(state, key) do
		seen = MapSet.put(state.seen, key)

		seen =
			if MapSet.size(seen) > @seen_limit do
				seen |> Enum.take(@seen_limit) |> MapSet.new()
			else
				seen
			end

		%{state | pending: MapSet.delete(state.pending, key), seen: seen}
	end

	defp safely_process_refresh(summary, state) do
		process_refresh(summary, state)
	rescue
		error -> {:error, Exception.message(error)}
	catch
		:exit, reason -> {:error, inspect(reason)}
	end

	# Discord only announces success. An empty/invalid market result means
	# "nothing worth posting", not something every channel should be pinged
	# about — log it and stay silent.
	#
	# Strict order: refresh done -> read -> broadcast. The single database
	# holds exactly what the pollers wrote, so the embed always renders
	# fresh data with no sync step in between.
	defp process_refresh(summary, state) do
		case fetch_channels(state) do
			{:ok, []} ->
				{:ok, :no_channels}

			{:ok, channels} ->
				case fetch_market_list(state) do
					{:ok, items} ->
						embed = Messages.market_list_embed(items)
						deliver_all(channels, embed, nil, state)

					{:error, reason} ->
						Marketmailer.Log.warning(
							"broadcast_no_market_item",
							%{region: Map.get(summary, :region), reason: inspect(reason)},
							"Skipping Discord broadcast: no market items"
						)

						{:ok, :no_market_item}
				end

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp fetch_channels(state) do
		case invoke(state.channels_fun) do
			{:ok, channels} when is_list(channels) -> {:ok, channels}
			{:ok, _other} -> {:error, :invalid_channels}
			{:error, reason} -> {:error, reason}
		end
	end

	defp fetch_market_list(state) do
		case invoke(state.market_fun) do
			{:ok, [_ | _] = items} -> {:ok, items}
			{:ok, []} -> {:error, :no_market_item}
			{:ok, _other} -> {:error, :invalid_market_result}
			{:error, reason} -> {:error, reason}
		end
	end

	defp deliver_all(channels, embed, file, state) do
		payload = message_payload(embed, file)

		Enum.reduce(channels, :ok, fn channel, result ->
			case invoke(fn -> state.deliver_fun.(channel, payload) end) do
				{:ok, {:ok, _response}} ->
					result

				{:ok, _other} ->
					result

				{:error, reason} ->
					if unknown_channel?(reason) do
						prune_bad_channel(state, channel, reason)
					else
						log_broadcast_failure("channel_send_failed", reason)
					end

					{:error, reason}
			end
		end)
	end

	defp message_payload(embed, nil), do: %{embeds: [embed], allowed_mentions: :none}

	defp message_payload(embed, file), do: %{embeds: [embed], files: [file], allowed_mentions: :none}

	defp invoke(fun) do
		case fun.() do
			{:error, reason} -> {:error, reason}
			value -> {:ok, value}
		end
	rescue
		error -> {:error, Exception.message(error)}
	catch
		:exit, reason -> {:error, inspect(reason)}
	end

	defp deliver(channel_id, payload) do
		case Bot.fetch_all_bots() do
			[%{name: name}] ->
				Bot.with_bot(name, fn -> Api.Message.create(channel_id, payload) end)

			[] ->
				{:error, :bot_unavailable}

			_bots ->
				{:error, :multiple_bots}
		end
	end

	defp log_broadcast_failure(event, reason) do
		Marketmailer.Log.warning(
			event,
			%{reason: inspect(reason)},
			"Discord market broadcast failed"
		)
	end

	# Discord 404/10003 Unknown Channel means the channel was deleted or the
	# bot lost access: drop the registration so later cycles stop retrying it.
	defp unknown_channel?(reason) do
		text = inspect(reason)
		String.contains?(text, "10003") or String.contains?(text, "Unknown Channel")
	end

	defp prune_bad_channel(state, channel, reason) do
		state.prune_fun.(channel)

		Marketmailer.Log.warning(
			"channel_pruned",
			%{channel_id: channel, reason: inspect(reason)},
			"Removed unknown Discord channel #{channel}"
		)
	rescue
		e ->
			Marketmailer.Log.warning(
				"channel_prune_failed",
				%{channel_id: channel, reason: Exception.message(e)},
				"Failed to remove unknown Discord channel #{channel}"
			)
	catch
		_, caught ->
			Marketmailer.Log.warning(
				"channel_prune_failed",
				%{channel_id: channel, reason: inspect(caught)},
				"Failed to remove unknown Discord channel #{channel}"
			)
	end
end

defmodule Discord.BotSupervisor do
	use Supervisor

	def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

	# Release-safe token reader for Nostrum's `wrapped_token` option.
	# Releases serialize sys.config and only allow `&Mod.fun/arity`
	# captures — anonymous closures like `fn -> ... end` are rejected at
	# `mix release` time. MFA captures survive and still read the env
	# lazily at boot (missing token → bot :ignore, rest keeps running).
	def token!, do: System.fetch_env!("DISCORD_TOKEN")

	@impl true
	def init(opts) do
		# Building nostrum's child spec fetches and validates the token
		# (wrapped_token). It raises on a missing or invalid token, so catch it
		# here and :ignore - the bot gets dropped and the rest of the tree runs.
		bot = Supervisor.child_spec({Nostrum.Bot, opts}, restart: :temporary)
		Supervisor.init([bot], strategy: :one_for_one)
	rescue
		e ->
			Marketmailer.Log.warning(
				"discord_bot_disabled",
				%{reason: Exception.message(e)},
				"Discord bot disabled (rest continues): #{Exception.message(e)}"
			)

			:ignore
	end
end
