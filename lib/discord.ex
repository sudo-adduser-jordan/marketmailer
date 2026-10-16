defmodule Discord.Messages do
	alias Nostrum.Struct.Embed
	alias Nostrum.Struct.Interaction

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	@icon_ "https://images.evetech.net/types/81008/icon?size=64"
	@icon_market "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/background.png"
	@icon_database "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/database.png"

	@icon_error "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/failure.png"
	@icon_success "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/success.png"

	defp with_version(%Embed{timestamp: ts} = embed) do
		%{embed | footer: %Embed.Footer{text: "#{ts} • v#{app_version()}"}, timestamp: nil}
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

	def candidate_name(%{item_name: name}) when is_binary(name), do: name
	def candidate_name(%{item: name}) when is_binary(name), do: name
	def candidate_name(%{name: name}) when is_binary(name), do: name
	def candidate_name(%{"item_name" => name}) when is_binary(name), do: name
	def candidate_name(%{"item" => name}) when is_binary(name), do: name
	def candidate_name(%{"name" => name}) when is_binary(name), do: name
	def candidate_name(_), do: nil

	@list_max 100

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

	def market_list_payload(items, page \\ 1, per_page \\ 10) do
		items = if is_list(items), do: items, else: []
		{list, page, per_page} = paginate(items, page, per_page)
		total_pages = max(1, ceil_div(length(list), per_page))

		%{embeds: [market_list_embed(list, page, per_page)], components: list_components(page, total_pages, length(list))}
	end

	def list_per_page, do: 10
	def list_broadcast_per_page, do: 100

	def round_status_embed(failures, pending) do
		failure_lines =
			failures
			|> Enum.sort_by(fn {region, _} -> region end)
			|> Enum.flat_map(fn {region, reasons} ->
				case List.wrap(reasons) do
					[] -> ["Region #{region} — refresh failed"]
					list -> Enum.map(list, fn reason -> "Region #{region} — #{format_failure(reason)}" end)
				end
			end)

		pending_lines =
			pending
			|> Enum.sort()
			|> Enum.map(fn region -> "Region #{region} — awaiting cycle" end)

		description = truncate_lines(failure_lines ++ pending_lines, "All regions reported.")

		%Embed{
			title: "Market cycle status",
			description: description,
			color: if(failures == %{}, do: @color_info, else: @color_error),
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

	defp format_failure(%{page: nil, reason: reason}), do: "failed: #{reason}"
	defp format_failure(%{page: page, reason: reason}), do: "page #{page}: #{reason}"
	defp format_failure(reason), do: "failed: #{inspect(reason)}"

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

	@list_item_width 18
	@list_system_width 10

	defp list_line(item, i) do
		name = list_truncate(list_field(item, :item, "item") || list_field(item, :item_name, "item_name"), @list_item_width)
		margin = format_list_margin(list_field(item, :margin, "margin"))
		system = list_truncate(list_field(item, :system_name, "system_name"), @list_system_width)
		security = format_security(list_field(item, :security_status, "security_status")) |> to_string()

		"#{i}. **#{name}** — #{margin} • #{system} (#{security})"
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

	defp truncate_lines([], acc), do: acc

	defp truncate_lines([line | rest], acc) do
		next = if acc == "", do: line, else: acc <> "\n" <> line

		if String.length(next) < 4000 do
			truncate_lines(rest, next)
		else
			acc
		end
	end

	defp format_isk(number) when is_number(number),
		do: (number * 1.0) |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

	defp location_value(item) do
		"#{or_unknown(item.location_name)} - #{or_unknown(item.system_name)} - #{or_unknown(item.region_name)} (#{format_security(item.security_status)})"
	end

	defp millions_compact(abs_value),
		do: :erlang.float_to_binary(Float.round(abs_value / 1_000_000, 2), decimals: 2) <> "M"

	defp to_number(nil), do: nil
	defp to_number(number) when is_number(number), do: number * 1.0

	defp to_number(binary) when is_binary(binary) do
		case Float.parse(String.trim(binary)) do
			{number, _} -> number
			:error -> nil
		end
	end

	defp to_number(_), do: nil

	defp per_unit_margin(item) do
		with buy when not is_nil(buy) <- to_number(item.buy_price),
				 sell when not is_nil(sell) <- to_number(item.price) do
			buy - sell
		else
			_ -> nil
		end
	end

	defp price_value(nil), do: "? ISK"

	defp price_value(price) when is_number(price) do
		abs_value = abs(price * 1.0)
		formatted = if abs_value >= 1_000_000, do: millions_compact(abs_value), else: format_isk(abs_value)
		prefix = if price < 0, do: "-", else: ""
		"#{prefix}#{formatted} ISK"
	end

	defp price_value(price) when is_binary(price) do
		case to_number(price) do
			nil -> "? ISK"
			number -> price_value(number)
		end
	end

	defp price_value(_), do: "? ISK"

	def market_embed(item, thumbnail_url \\ nil, image_url \\ nil) do
		janice_url = "https://janice.e-351.com/i/#{item.type_id}/market/2"
		eve_ref_url = "https://everef.net/types/#{item.type_id}"
		eve_tycoon_url = "https://evetycoon.com/market/#{item.type_id}"
		type_icon = "https://images.evetech.net/types/#{item.type_id}/icon?size=64"

		%Embed{
			title: item.item_name || "Market order",
			description: "[Janice](#{janice_url})\n[Eve Ref](#{eve_ref_url})\n[Eve Tycoon](#{eve_tycoon_url})",
			color: embed_color(per_unit_margin(item)),
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
					value: margin_value(per_unit_margin(item)),
					inline: false
				}
			]
		}
		|> with_version()
	end

	defp embed_color(nil), do: @color_info
	defp embed_color(profit) when is_number(profit) and profit > 0, do: @color_success
	defp embed_color(_profit), do: @color_error

	defp margin_value(nil), do: "? ISK"

	defp margin_value(profit) when is_number(profit) do
		sign = if profit >= 0, do: "+", else: "-"
		abs_value = abs(profit * 1.0)

		if abs_value >= 1_000_000 do
			"#{sign}#{millions_compact(abs_value)} ISK"
		else
			"#{sign}#{format_isk(abs_value)} ISK"
		end
	end

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
	alias Nostrum.Cache.Me
	alias Nostrum.Constants
	alias Nostrum.Constants.ApplicationCommandOptionType
	alias Nostrum.Constants.InteractionCallbackType
	alias Nostrum.Struct.Interaction

	@admin_only "16"

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

		Api.request(:put, Constants.global_application_commands(Me.get().id), server_commands ++ market_commands)
	end

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
					nil ->
						respond(interaction, Messages.market_list_payload(safe_get_items(), 1, Messages.list_per_page()))

					bot_name ->
						response = %{
							type: InteractionCallbackType.deferred_channel_message_with_source()
						}

						try do
							case Api.Interaction.create_response(interaction, response) do
								:ok -> start_list_task(bot_name, interaction)
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

	defp option_value(%{data: %{options: options}}, name) when is_list(options) do
		Enum.find_value(options, fn
			%{name: ^name, value: value} -> value
			_ -> nil
		end)
	end

	defp option_value(_interaction, _name), do: nil

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
		Market.Database.suggest_items(item_name, limit)
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

	defp candidate_name(candidate), do: Messages.candidate_name(candidate)

	defp exact_item_match?(input, item, candidates) do
		normalize_item(input) != "" and
			(normalize_item(input) == normalize_item(item.item_name) or
				 Enum.any?(candidates, fn candidate -> normalize_item(input) == normalize_item(candidate_name(candidate)) end))
	end

	defp normalize_item(name) when is_binary(name), do: Market.Database.normalize_item_name(name)

	defp normalize_item(_), do: ""

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
		respond(intr, %{embeds: [embed]})
	end

	defp respond(intr, %{embeds: embeds} = payload) do
		data =
			case Map.fetch(payload, :components) do
				{:ok, components} -> %{embeds: embeds, components: components}
				:error -> %{embeds: embeds}
			end

		case Api.Interaction.create_response(intr, %{type: 4, data: data}) do
			:ok -> :ok
			{:error, reason} -> log_discord_warning("discord_respond_failed", reason, intr)
		end
	rescue
		error -> log_discord_warning("discord_respond_failed", Exception.message(error), intr)
	catch
		_, reason -> log_discord_warning("discord_respond_failed", reason, intr)
	end
end

defmodule Discord.Broadcaster do
	use GenServer

	alias Discord.Database, as: DiscordDatabase
	alias Discord.Messages
	alias Marketmailer.RegionManager
	alias Nostrum.Api
	alias Nostrum.Bot

	@seen_limit 10_000
	@round_timeout 10 * 60_000

	def start_link(opts \\ []) do
		name = Keyword.get(opts, :name, __MODULE__)
		GenServer.start_link(__MODULE__, opts, name: name)
	end

	@impl true
	def init(opts) do
		regions = Keyword.get(opts, :regions, Marketmailer.RegionManagerSupervisor.region_ids())
		Enum.each(regions, &subscribe_region/1)

		state = %{
			async: Keyword.get(opts, :async, true),
			task_supervisor: Keyword.get(opts, :task_supervisor, Marketmailer.TaskSup),
			channels_fun: Keyword.get(opts, :channels_fun, :default),
			market_fun: Keyword.get(opts, :market_fun, :default),
			deliver_fun: Keyword.get(opts, :deliver_fun, :default),
			prune_fun: Keyword.get(opts, :prune_fun, :default),
			regions: regions,
			round: Keyword.get(opts, :round, 1),
			round_timeout: Keyword.get(opts, :round_timeout, @round_timeout),
			reports: %{},
			seen: MapSet.new(),
			round_timer: nil
		}

		{:ok, schedule_round(state)}
	end

	@impl true
	def code_change(_vsn, state, _extra) when is_map(state) do
		state =
			state
			|> Map.delete(:pending)
			|> Map.merge(%{
				regions: Map.get(state, :regions, Marketmailer.RegionManagerSupervisor.region_ids()),
				round: Map.get(state, :round, 1),
				round_timeout: Map.get(state, :round_timeout, @round_timeout),
				reports: %{},
				seen: Map.get(state, :seen, MapSet.new()),
				round_timer: nil
			})
			|> Map.new(fn
				{key, fun} when key in [:channels_fun, :market_fun, :deliver_fun, :prune_fun] and is_function(fun) ->
					{key, :default}

				{k, v} ->
					{k, v}
			end)

		{:ok, schedule_round(state)}
	end

	@impl true
	def handle_info({:region_refresh_complete, summary}, state) do
		record_report(summary, :complete, state)
	end

	def handle_info({:region_refresh_unchanged, summary}, state) do
		record_report(summary, :unchanged, state)
	end

	def handle_info({:region_refresh_failed, summary}, state) do
		record_report(summary, {:failed, Map.get(summary, :failures, [])}, state)
	end

	def handle_info({:broadcast_done, _key, result}, state) do
		case result do
			:ok -> :ok
			{:ok, _value} -> :ok
			{:error, reason} -> log_broadcast_failure("broadcast_failed", reason)
		end

		{:noreply, state}
	end

	def handle_info({:round_timeout, round}, %{round: round} = state) do
		close_round(state)
	end

	def handle_info(_message, state), do: {:noreply, state}

	@impl true
	def handle_cast(message, state), do: handle_info(message, state)

	defp subscribe_region(region) do
		RegionManager.subscribe(region, self())
		:ok
	catch
		:exit, _ -> :ok
	end

	defp record_report(summary, outcome, state) do
		region = Map.get(summary, :region)
		cycle_id = Map.get(summary, :cycle_id)
		key = {region, cycle_id}

		if MapSet.member?(state.seen, key) do
			{:noreply, state}
		else
			state = note_seen(state, key)
			state = %{state | reports: Map.put(state.reports, region, {cycle_id, outcome})}

			if Enum.all?(state.regions, &Map.has_key?(state.reports, &1)) do
				close_round(state)
			else
				{:noreply, state}
			end
		end
	end

	defp close_round(state) do
		cancel_round_timer(state)

		pending = Enum.reject(state.regions, &Map.has_key?(state.reports, &1))
		snapshot = %{round: state.round, reports: state.reports, pending: pending}
		state = %{state | round: state.round + 1, reports: %{}}
		state = schedule_round(state)

		if state.async do
			start_async_digest(state, snapshot)
		else
			case safely_process_digest(snapshot, state) do
				:ok -> :ok
				{:ok, _value} -> :ok
				{:error, reason} -> log_broadcast_failure("broadcast_failed", reason)
			end

			{:noreply, state}
		end
	end

	defp start_async_digest(state, snapshot) do
		owner = self()

		case Task.Supervisor.start_child(state.task_supervisor, fn ->
					 result = safely_process_digest(snapshot, state)
					 send(owner, {:broadcast_done, snapshot.round, result})
				 end) do
			{:ok, _pid} ->
				{:noreply, state}

			{:error, reason} ->
				log_broadcast_failure("broadcast_task_failed", reason)
				{:noreply, state}
		end
	end

	defp schedule_round(%{round_timer: nil} = state) do
		handle = Process.send_after(self(), {:round_timeout, state.round}, state.round_timeout)
		%{state | round_timer: handle}
	end

	defp schedule_round(state) do
		cancel_round_timer(state)
		schedule_round(%{state | round_timer: nil})
	end

	defp cancel_round_timer(%{round_timer: nil}), do: :ok

	defp cancel_round_timer(%{round_timer: handle}) do
		Process.cancel_timer(handle)
		:ok
	end

	defp note_seen(state, key) do
		seen = MapSet.put(state.seen, key)

		seen =
			if MapSet.size(seen) > @seen_limit do
				seen |> Enum.take(@seen_limit) |> MapSet.new()
			else
				seen
			end

		%{state | seen: seen}
	end

	defp safely_process_digest(snapshot, state) do
		process_digest(snapshot, state)
	rescue
		error -> {:error, Exception.message(error)}
	catch
		:exit, reason -> {:error, inspect(reason)}
	end

	defp process_digest(snapshot, state) do
		case fetch_channels(state) do
			{:ok, []} ->
				{:ok, :no_channels}

			{:ok, channels} ->
				items = fetch_market_list(state)
				failures = digest_failures(snapshot.reports)
				payload = digest_payload(items, failures, snapshot.pending)
				deliver_all(channels, payload, state)

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp digest_payload(items, failures, pending) do
		base = Messages.market_list_payload(items, 1, Messages.list_broadcast_per_page())

		if failures == %{} and pending == [] do
			base
		else
			%{base | embeds: base.embeds ++ [Messages.round_status_embed(failures, pending)]}
		end
	end

	defp digest_failures(reports) do
		for {region, {_cycle_id, {:failed, reasons}}} <- reports, into: %{} do
			{region, reasons}
		end
	end

	defp fetch_channels(state) do
		case invoke_resolve(state, :channels_fun, {DiscordDatabase, :registered_channels, []}) do
			{:ok, channels} when is_list(channels) -> {:ok, channels}
			{:ok, _other} -> {:error, :invalid_channels}
			{:error, reason} -> {:error, reason}
		end
	end

	defp fetch_market_list(state) do
		case invoke_resolve(state, :market_fun, {Market.Database, :get_items_less_than_jita_buy, []}) do
			{:ok, items} when is_list(items) ->
				items

			{:ok, other} ->
				Marketmailer.Log.warning(
					"broadcast_invalid_market_result",
					%{result: inspect(other)},
					"Market query returned an unexpected shape; broadcasting an empty list"
				)

				[]

			{:error, reason} ->
				Marketmailer.Log.warning(
					"broadcast_market_lookup_failed",
					%{reason: inspect(reason)},
					"Market query failed; broadcasting an empty list"
				)

				[]
		end
	end

	defp invoke_resolve(state, key, {mod, fun, args}) do
		case Map.get(state, key, :default) do
			:default -> invoke(fn -> apply(mod, fun, args) end)
			override when is_function(override) -> invoke(fn -> apply(override, args) end)
			other -> {:error, {:invalid_override, key, other}}
		end
	end

	defp deliver_all(channels, payload, state) do
		message = Map.put(payload, :allowed_mentions, :none)

		Enum.reduce(channels, :ok, fn channel, result ->
			case invoke_resolve(state, :deliver_fun, {__MODULE__, :deliver, [channel, message]}) do
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

	def deliver(channel_id, payload) do
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

	defp unknown_channel?(reason) do
		text = inspect(reason)
		String.contains?(text, "10003") or String.contains?(text, "Unknown Channel")
	end

	defp prune_bad_channel(state, channel, reason) do
		_ = invoke_resolve(state, :prune_fun, {DiscordDatabase, :delete_by_channel, [channel]})

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

	def token!, do: System.fetch_env!("DISCORD_TOKEN")

	@impl true
	def init(opts) do
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
