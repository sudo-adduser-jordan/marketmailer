defmodule Discord.Embeds do
	alias Marketmailer.Utils
	alias Nostrum.Struct.Embed

	@list_max 100

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA
	@color_warning 0xFAA61A
	@color_contract 0x7B68EE

	@icon_ "https://images.evetech.net/types/52678/icon?size=64"
	@icon_market "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/background.png"
	@icon_database "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/database.png"
	@icon_broadcast "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/broadcast.png"
	@icon_error "https://raw.githubusercontent.com/sudo-adduser-jordan/marketmailer/refs/heads/main/assets/failure.png"

	defp with_version(%Embed{timestamp: ts} = embed) do
		%{embed | footer: %Embed.Footer{text: "#{Utils.format_footer_date(ts)} • v#{app_version()}"}, timestamp: nil}
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
			author: %Embed.Author{name: "\u200B", icon_url: @icon_error},
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
			author: %Embed.Author{name: "\u200B", icon_url: @icon_error},
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
			author: %Embed.Author{name: "\u200B", icon_url: @icon_error},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			}
		}
		|> with_version()
	end

	def capital_ship_embed(item_name) do
		item_name = if is_binary(item_name), do: String.trim(item_name), else: ""
		item_name = if item_name == "", do: "that item", else: item_name

		%Embed{
			title: "Not tradable in high sec",
			description:
				"**#{item_name}** is a capital hull that cannot enter high security space, so it cannot be sold or delivered in Jita. It is excluded from the Jita buy-wall checks.",
			color: @color_warning,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
			thumbnail: %Embed.Thumbnail{
				url: @icon_market
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
			author: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
			thumbnail: %Embed.Thumbnail{
				url: @icon_
			}
		}
		|> with_version()
	end

	def candidate_name(candidate) when is_map(candidate) do
		[:item_name, :item, :name, "item_name", "item", "name"]
		|> Enum.map(&Map.get(candidate, &1))
		|> Enum.find(&is_binary/1)
	end

	def candidate_name(_), do: nil

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

		lines = Enum.map(page_items, &list_line/1)

		description =
			if page_items == [] do
				"No items are undercutting the Jita buy wall right now."
			else
				truncate_lines(lines, "")
			end

		total_pages = max(1, ceil_div(length(capped), per_page))

		pages =
			if total_pages > 1 do
				"(#{page}/#{total_pages})"
			else
				""
			end

		%Embed{
			author: %Embed.Author{
				name: "Jita Buy Wall #{pages}",
				icon_url: @icon_broadcast
			},
			description: description,
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
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

	def payload(%Embed{} = embed), do: %{embeds: [embed]}
	def payload(payload), do: payload

	def list_per_page, do: 10

	def market_list_message(items), do: market_list_payload(items, 1, list_per_page())

	def contract_list_payload(contracts, page, config) do
		per_page = config |> Keyword.fetch!(:broadcast_per_page) |> max(1)
		limit = Keyword.fetch!(config, :broadcast_limit)
		contracts = Enum.take(List.wrap(contracts), limit)
		total_pages = max(1, ceil_div(length(contracts), per_page))
		page = clamp_page(page, total_pages)
		page_items = list_page_slice(contracts, page, per_page)

		description =
			if page_items == [] do
				"No contracts meet the 100m ISK margin this cycle."
			else
				truncate_lines(Enum.map(page_items, &contract_line/1), "")
			end

		title =
			if total_pages > 1 do
				"Contracts (#{page}/#{total_pages})"
			else
				"Contracts"
			end

		%{
			embeds: [
				%Embed{
					author: %Embed.Author{name: title, icon_url: @icon_broadcast},
					description: description,
					color: @color_contract,
					timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
				}
				|> with_version()
			],
			components: contract_list_components(page, total_pages)
		}
	end

	def contract_list_empty_payload(message) do
		%{
			embeds: [
				%Embed{
					author: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
					title: "Contract arbitrage",
					description: message,
					color: @color_contract,
					timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
				}
				|> with_version()
			],
			components: []
		}
	end

	def contract_list_error_payload do
		%{
			embeds: [
				%Embed{
					author: %Embed.Author{name: "\u200B", icon_url: @icon_error},
					title: "Contracts unavailable",
					description: "The contract list could not be loaded. Try again after the next contract round.",
					color: @color_error,
					timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
				}
				|> with_version()
			],
			components: []
		}
	end

	defp contract_line(contract) do
		name = contract_name(contract)
		capital = if contract.has_capital == 1, do: " [CAPITAL]", else: ""
		price = contract.price || contract.buyout || 0
		items = contract_item_label(contract)
		location = "#{contract.region_name} / #{contract.location_name}"

		"**#{Utils.list_truncate(name, 48)}**#{capital} • #{location} • " <>
			"#{format_isk_compact(price)} → #{format_isk_compact(contract.items_value)} " <>
			"(**+#{format_isk_compact(contract.margin)}**) • #{items} • " <>
			"#{contract_expiry_label(contract.expires_at)} • `#{contract.contract_id}`"
	end

	defp contract_name(%{title: title, contract_id: id}) do
		title = String.trim(title || "")
		if title == "", do: "Contract #{id}", else: title
	end

	defp contract_item_label(contract) do
		names = contract |> Map.get(:item_names, []) |> Enum.take(3)
		count = contract.item_count || length(names)

		if names == [] do
			"#{count} item(s)"
		else
			"#{count} item(s): #{Enum.join(names, ", ")}"
		end
	end

	defp contract_expiry_label(nil), do: "expiry unknown"

	defp contract_expiry_label(expires_at) when is_integer(expires_at) do
		remaining = expires_at - Contracts.now_ms()

		cond do
			remaining <= 0 ->
				"expired"

			remaining >= 86_400_000 ->
				"expires #{div(remaining, 86_400_000)}d #{div(rem(remaining, 86_400_000), 3_600_000)}h"

			remaining >= 3_600_000 ->
				"expires #{div(remaining, 3_600_000)}h #{div(rem(remaining, 3_600_000), 60_000)}m"

			true ->
				"expires #{div(remaining, 60_000)}m"
		end
	end

	defp format_isk_compact(number) when is_number(number) do
		value = number * 1.0
		absolute = abs(value)

		cond do
			absolute >= 1_000_000_000 -> "#{Float.round(value / 1_000_000_000, 1)}b ISK"
			absolute >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}m ISK"
			absolute >= 1_000 -> "#{Float.round(value / 1_000, 1)}k ISK"
			true -> "#{round(value)} ISK"
		end
	end

	defp format_isk_compact(_number), do: "? ISK"

	defp contract_list_components(_page, total_pages) when total_pages <= 1, do: []

	defp contract_list_components(page, total_pages), do: pager_components("contract_list", page, total_pages)

	def round_status_embed(failures, pending) do
		description = truncate_lines(status_lines(failures, pending), "All regions reported.")

		%Embed{
			title: "Market cycle status",
			description: description,
			color: if(failures == %{}, do: @color_info, else: @color_error),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			author:
				if(failures == %{},
					do: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
					else: %Embed.Author{name: "\u200B", icon_url: @icon_error}
				),
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
			author: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
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
			author: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
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
					list -> Enum.map(list, fn reason -> "Region #{region} — #{Utils.format_failure(reason)}" end)
				end
			end)

		pending_lines =
			pending
			|> Enum.sort()
			|> Enum.map(fn region -> "Region #{region} — awaiting cycle" end)

		failure_lines ++ pending_lines
	end

	def list_components(_page, _total_pages, 0), do: []

	def list_components(_page, total_pages, _count) when total_pages <= 1, do: []

	def list_components(page, total_pages, _count), do: pager_components("market_list", page, total_pages)

	defp pager_components(_prefix, _page, total_pages) when total_pages <= 1, do: []

	defp pager_components(prefix, page, total_pages) do
		[
			%{
				type: 1,
				components: [
					%{
						type: 2,
						style: 2,
						label: "Prev",
						custom_id: "#{prefix}:page:#{page - 1}",
						disabled: page <= 1
					},
					%{
						type: 2,
						style: 2,
						label: "Next",
						custom_id: "#{prefix}:page:#{page + 1}",
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

	defp list_field(item, atom_key, string_key) when is_map(item),
		do: Map.get(item, atom_key) || Map.get(item, string_key)

	defp list_field(_item, _atom_key, _string_key), do: nil

	@list_item_width 18
	@list_system_width 10

	defp list_line(item) do
		name = list_name(item)
		margin = Utils.format_list_margin(list_field(item, :margin, "margin"))
		system = Utils.list_truncate(list_field(item, :system_name, "system_name"), @list_system_width)
		security = Utils.format_security(list_field(item, :security_status, "security_status")) |> to_string()

		"**#{name}** • #{margin} • #{system} • #{security}"
	end

	defp list_name(item) do
		name = list_field(item, :item, "item") || list_field(item, :item_name, "item_name")

		if is_binary(name) and String.trim(name) != "" do
			Utils.list_truncate(name, @list_item_width)
		else
			type_label(item)
		end
	end

	defp type_label(item) do
		case list_field(item, :type_id, "type_id") do
			id when is_integer(id) and id > 0 -> "Type #{id}"
			_ -> "?"
		end
	end

	@description_limit 4000

	defp truncate_lines(lines, empty) do
		case collect_lines(lines, "") do
			{"", 0} -> empty
			{text, 0} -> text
			{"", dropped} -> more_line(dropped)
			{text, dropped} -> text <> "\n" <> more_line(dropped)
		end
	end

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

	defp location_value(item) do
		"#{Utils.or_unknown(item.location_name)} - #{Utils.or_unknown(item.system_name)} - #{Utils.or_unknown(item.region_name)} • #{Utils.format_security(item.security_status)}"
	end

	defp per_unit_margin(item) do
		with buy when not is_nil(buy) <- Utils.to_number(item.buy_price),
				 sell when not is_nil(sell) <- Utils.to_number(item.price) do
			buy - sell
		else
			_ -> nil
		end
	end

	def market_embed(item, thumbnail_url \\ nil, image_url \\ nil) do
		janice_url = "https://janice.e-351.com/i/#{item.type_id}/market/2"
		eve_ref_url = "https://everef.net/types/#{item.type_id}"
		eve_tycoon_url = "https://evetycoon.com/market/#{item.type_id}"
		type_icon = "https://images.evetech.net/types/#{item.type_id}/icon?size=64"

		%Embed{
			author: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast},
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
					value: Utils.price_value(item.price),
					inline: true
				},
				%Embed.Field{
					name: "Buy",
					value: Utils.price_value(item.buy_price),
					inline: true
				},
				%Embed.Field{
					name: "Margin",
					value: Utils.margin_value(per_unit_margin(item)),
					inline: false
				}
			]
		}
		|> with_version()
	end

	defp embed_color(nil), do: @color_info
	defp embed_color(profit) when is_number(profit) and profit > 0, do: @color_success
	defp embed_color(_profit), do: @color_error

	defp channel_embed(description, color) do
		%Embed{
			author:
				if(color == @color_error,
					do: %Embed.Author{name: "\u200B", icon_url: @icon_error},
					else: %Embed.Author{name: "\u200B", icon_url: @icon_broadcast}
				),
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

	def database_stats_embed(stats) do
		stats = if is_map(stats), do: stats, else: %{}

		%Embed{
			author: %Embed.Author{
				name: "\u200BDatabase Statistics",
				icon_url: @icon_broadcast
			},
			color: @color_info,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_database
			},
			fields: [
				%Embed.Field{name: "## Status", value: status_value(stats)},
				%Embed.Field{name: "## Storage", value: storage_value(stats)},
				%Embed.Field{name: "## Coverage", value: coverage_value(stats)},
				%Embed.Field{name: "## Orders", value: order_cache_value(stats)},
				%Embed.Field{name: "## Contracts", value: contracts_value(stats)},
				%Embed.Field{name: "## Jita Buy Wall", value: undercut_value(stats)},
				%Embed.Field{name: "## Commands", value: commands_value()}
			]
		}
		|> with_version()
	end

	def database_stats_error_embed do
		%Embed{
			author: %Embed.Author{name: "\u200B", icon_url: @icon_error},
			title: "Database Statistics",
			description: "The database statistics could not be read.",
			color: @color_error,
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
			thumbnail: %Embed.Thumbnail{
				url: @icon_database
			}
		}
		|> with_version()
	end

	defp order_cache_value(stats) do
		"""
		**Orders**: #{Utils.format_count(stats[:order_count])}
		**Sell**: #{Utils.format_count(stats[:sell_orders])}
		**Buy**: #{Utils.format_count(stats[:buy_orders])}
		**Types**: #{Utils.format_count(stats[:tracked_types])}
		**Systems**: #{Utils.format_count(stats[:tracked_systems])}
		**Oldest order**: #{Utils.format_timestamp(stats[:first_write_at])}
		"""
		|> String.trim_trailing()
	end

	defp storage_value(stats) do
		"""
		**Provider**: SQLite
		**Size**: #{Utils.format_bytes(stats[:page_count], stats[:page_size])}
		**Journal Mode**: #{stats[:journal_mode]}
		**Schema Version**: #{stats[:schema_version]}
		**Last write**: #{Utils.relative_age(stats[:last_write_at])}
		**Query**: #{Utils.format_milliseconds(stats[:query_ms])}
		"""
		|> String.trim_trailing()
	end

	defp undercut_value(stats) do
		"""
		**Undercut**: #{Utils.format_count(stats[:undercut_rows])} orders undercut the Jita buy wall — `/list_market` shows the top 100.
		**Types**: #{Utils.count(stats[:jita_buy_types])}
		"""
		|> String.trim_trailing()
	end

	defp commands_value do
		"/check_market • /list_market • /list_contracts • /database_stats • /add_channel • /remove_channel • /list_channel"
	end

	defp contracts_value(stats) do
		"""
		**Cached**: #{Utils.count(stats[:contract_count])}
		**Regions**: #{Utils.count(stats[:contract_regions])}
		**Rows**: #{Utils.count(stats[:contract_items_count])}
		**Items**: resolved #{Utils.count(stats[:contracts_resolved])} • pending #{Utils.count(stats[:contracts_pending])} • failed #{Utils.count(stats[:contracts_failed])}
		**Workers**: #{Utils.count(stats[:contract_page_workers])}
		**Active Round**: #{round_state(stats[:contract_active_round])}
		**Top Round**: #{round_label(stats[:contract_top_round])}
		**Last Desired**: #{Utils.count(stats[:contract_last_desired])}
		**Last Seen**: #{round_label(stats[:contract_last_seen_round])}
		"""
		|> String.trim_trailing()
	end

	defp coverage_value(stats) do
		types = Utils.count(stats[:tracked_types])
		names = Utils.count(stats[:known_names])

		"""
		**Names**: #{names} / systems: #{Utils.count(stats[:known_systems])} in the SDE cache
		**Types with orders**: #{types} of #{names} known names
		**Unnamed locations**: #{Utils.count(stats[:unnamed_locations])}
		**#{Utils.share(stats[:unnamed_locations], stats[:order_count])}** of orders
		**Unknown systems**: #{Utils.count(stats[:unknown_systems])}
		"""
		|> String.trim_trailing()
	end

	defp status_value(stats) do
		"""
		**Network**: #{network_value(stats[:network])}
		**Regions**: #{Utils.count(stats[:regions])}
		**Workers**: #{Utils.count(stats[:page_workers])}
		**Etags**: #{Utils.count(stats[:etag_pages])}
		**ETS cache**: #{Utils.count(stats[:cache_entries])}
		**Errors**: #{Utils.count(stats[:esi_error_entries])}
		**Rate**: #{Utils.count(stats[:esi_rate_entries])}
		**Janice**: #{Utils.count(stats[:janice_cache_entries])}
		**Registered channels**: #{Utils.count(stats[:alert_channels])}
		**Uptime**: #{Utils.format_uptime(stats[:uptime_seconds])}
		**SDE**: #{stats[:sde_build]}
		"""
		|> String.trim_trailing()
	end

	defp network_value(%{state: :down} = status) do
		case status[:reason] do
			reason when is_binary(reason) and reason != "" -> "DOWN (#{reason})"
			_ -> "DOWN"
		end
	end

	defp network_value(_status), do: "up"

	defp round_state(nil), do: "idle"
	defp round_state(_), do: "running"

	defp round_label(nil), do: "none"
	defp round_label(value) when is_integer(value), do: "##{Utils.format_count(value)}"
	defp round_label(_), do: "none"
end
