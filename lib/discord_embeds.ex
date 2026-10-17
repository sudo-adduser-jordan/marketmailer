defmodule Discord.Embeds do
	alias Nostrum.Struct.Embed

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA
	@color_warning 0xFAA61A

	# Jita IV - Moon 4 - Caldari Navy Assembly Plant (station 60003760, type 52678).
	# ESI exposes no station-icon route, so the market embeds use the station's type icon.
	@icon_ "https://images.evetech.net/types/52678/icon?size=64"
	@icon_market "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/background.png"
	@icon_database "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/database.png"

	@icon_broadcast "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/broadcast.png"
	@icon_error "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/failure.png"

	defp branded_author(icon_url \\ @icon_broadcast) do
		%Embed.Author{name: "\u200B", icon_url: icon_url}
	end

	defp error_author, do: branded_author(@icon_error)

	defp with_version(%Embed{timestamp: ts} = embed) do
		%{embed | footer: %Embed.Footer{text: "#{format_footer_date(ts)} • v#{app_version()}"}, timestamp: nil}
	end

	defp format_footer_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M UTC")

	defp format_footer_date(ts) when is_binary(ts) do
		case DateTime.from_iso8601(String.trim(ts)) do
			{:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y %H:%M UTC")
			_ -> Calendar.strftime(DateTime.utc_now(), "%b %d, %Y %H:%M UTC")
		end
	end

	defp format_footer_date(_), do: Calendar.strftime(DateTime.utc_now(), "%b %d, %Y %H:%M UTC")

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
			author: error_author(),
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
			author: error_author(),
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
			author: error_author(),
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
			author: branded_author(),
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
			author: branded_author(),
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

	# The slash command and the broadcaster render the exact same page.
	def market_list_message(items), do: market_list_payload(items, 1, list_per_page())

	def round_status_embed(failures, pending) do
		description = truncate_lines(status_lines(failures, pending), "All regions reported.")

		%Embed{
			title: "Market cycle status",
			description: description,
			color: if(failures == %{}, do: @color_info, else: @color_error),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: if(failures == %{}, do: branded_author(), else: error_author()),
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			}
		}
		|> with_version()
	end

	def esi_down_embed do
		%Embed{
			title: "ESI is down",
			description: "Market data is stale; ESI appears to be down.",
			color: @color_warning,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: branded_author(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			}
		}
		|> with_version()
	end

	def no_update_embed(failures \\ %{}) do
		description =
			if failures == %{} do
				"No regions reported updated orders this cycle."
			else
				truncate_lines(status_lines(failures, []), "No regions reported updated orders this cycle.")
			end

		%Embed{
			title: "No market updates",
			description: description,
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: branded_author(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			}
		}
		|> with_version()
	end

	defp status_lines(failures, pending) do
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

		failure_lines ++ pending_lines
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

	@description_limit 4000

	defp truncate_lines(lines, empty) do
		case collect_lines(lines, "") do
			{"", 0} -> empty
			{text, 0} -> text
			{"", dropped} -> more_line(dropped)
			{text, dropped} -> text <> "\n" <> more_line(dropped)
		end
	end

	# Lines that do not fit are reported, never dropped silently.
	defp collect_lines([], acc), do: {acc, 0}

	defp collect_lines([line | rest], acc) do
		next = if acc == "", do: line, else: acc <> "\n" <> line

		if String.length(next) < @description_limit do
			collect_lines(rest, next)
		else
			{acc, length([line | rest])}
		end
	end

	defp more_line(dropped), do: "… +#{dropped} more"

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
			author: branded_author(),
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
			author: if(color == @color_error, do: error_author(), else: branded_author()),
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
