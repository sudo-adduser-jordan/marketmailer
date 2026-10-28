defmodule Discord.Consumer do
	@behaviour Nostrum.Consumer

	alias Discord.Embeds
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
			},
			%{
				name: "list_contracts",
				description: "Profitable public contracts",
				integration_types: @both_installs,
				contexts: @any_context
			},
			%{
				name: "database_stats",
				description: "Show database and market cache statistics",
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
		payload = Embeds.market_list_payload(safe_get_items(), page, Embeds.list_per_page())

		Api.Interaction.create_response(interaction, %{
			type: InteractionCallbackType.update_message(),
			data: payload
		})
	end

	def handle_event(
				{:INTERACTION_CREATE, %Interaction{type: 3, data: %{custom_id: "contract_list:page:" <> _}} = interaction, _}
			) do
		case active_bot_name() do
			nil ->
				page = contract_page_from_custom_id(interaction)
				payload = Contracts.Broadcast.page_payload(page)

				Api.Interaction.create_response(interaction, %{
					type: InteractionCallbackType.update_message(),
					data: payload
				})

			bot_name ->
				response = %{type: InteractionCallbackType.deferred_update_message()}

				try do
					case Api.Interaction.create_response(interaction, response) do
						:ok -> start_contracts_page_task(bot_name, interaction)
						{:error, reason} -> log_discord_warning("contracts_page_defer_failed", reason, interaction)
					end
				rescue
					error -> log_discord_warning("contracts_page_defer_failed", Exception.message(error), interaction)
				catch
					_, reason -> log_discord_warning("contracts_page_defer_failed", reason, interaction)
				end
		end
	end

	def handle_event({:INTERACTION_CREATE, %Interaction{data: %{name: name}} = interaction, _}) do
		case name do
			"add_channel" ->
				if is_nil(interaction.guild_id) do
					respond(interaction, Embeds.server_only(interaction))
				else
					Discord.Database.upsert(interaction.guild_id, interaction.channel_id)
					respond(interaction, Embeds.add_channel(interaction))
				end

			"remove_channel" ->
				if is_nil(interaction.guild_id) do
					respond(interaction, Embeds.server_only(interaction))
				else
					Discord.Database.delete(interaction.guild_id)
					respond(interaction, Embeds.channel_removed(interaction))
				end

			"list_channel" ->
				if is_nil(interaction.guild_id) do
					respond(interaction, Embeds.server_only(interaction))
				else
					channel_id = Discord.Database.get(interaction.guild_id)
					respond(interaction, Embeds.list_channel(channel_id))
				end

			"check_market" ->
				item_name = option_value(interaction, "item")

				case safe_get_capital_item(item_name) do
					nil -> reply_with_market_item(interaction, item_name)
					capital -> respond(interaction, Embeds.capital_ship_embed(capital.item_name))
				end

			"list_market" ->
				case active_bot_name() do
					nil ->
						respond(interaction, Embeds.market_list_message(safe_get_items()))

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

			"list_contracts" ->
				case active_bot_name() do
					nil ->
						respond_with_contracts(interaction)

					bot_name ->
						response = %{
							type: InteractionCallbackType.deferred_channel_message_with_source()
						}

						try do
							case Api.Interaction.create_response(interaction, response) do
								:ok -> start_contracts_task(bot_name, interaction)
								{:error, reason} -> contracts_defer_fallback(interaction, reason)
							end
						rescue
							error ->
								contracts_defer_fallback(interaction, Exception.message(error))
						catch
							_, reason -> contracts_defer_fallback(interaction, reason)
						end
				end

			"database_stats" ->
				case active_bot_name() do
					nil ->
						respond(interaction, stats_payload(interaction))

					bot_name ->
						response = %{
							type: InteractionCallbackType.deferred_channel_message_with_source()
						}

						try do
							case Api.Interaction.create_response(interaction, response) do
								:ok -> start_stats_task(bot_name, interaction)
								{:error, reason} -> stats_defer_fallback(interaction, reason)
							end
						rescue
							error ->
								stats_defer_fallback(interaction, Exception.message(error))
						catch
							_, reason -> stats_defer_fallback(interaction, reason)
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

	defp safe_get_capital_item(item_name) do
		Market.Database.get_capital_item(item_name)
	rescue
		error ->
			Marketmailer.Log.warning(
				"check_market_lookup_failed",
				%{reason: Exception.message(error)},
				"check_market capital lookup failed; replying not-found"
			)

			nil
	catch
		_, reason ->
			Marketmailer.Log.warning(
				"check_market_lookup_failed",
				%{reason: inspect(reason)},
				"check_market capital lookup failed; replying not-found"
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

	defp reply_with_market_item(interaction, item_name) do
		candidates = safe_suggest_items(item_name, 10)

		case safe_get_market_item(item_name) do
			nil ->
				reply_for_missing_item(interaction, item_name, candidates)

			item ->
				if exact_item_match?(item_name, item, candidates) or length(candidates) <= 1 do
					reply_with_detail(interaction, item)
				else
					respond(interaction, Embeds.market_disambiguation_embed(item_name, candidates))
				end
		end
	end

	defp reply_with_detail(interaction, item) do
		respond(interaction, Embeds.market_embed(item))

		case active_bot_name() do
			nil -> :ok
			bot_name -> start_chart_task(bot_name, interaction, item)
		end
	end

	defp reply_for_missing_item(interaction, item_name, [single]) do
		case safe_get_market_item(candidate_name(single)) do
			nil -> respond(interaction, Embeds.market_disambiguation_embed(item_name, [single]))
			item -> reply_with_detail(interaction, item)
		end
	end

	defp reply_for_missing_item(interaction, item_name, candidates) do
		if candidates == [] do
			respond(interaction, Embeds.market_not_found_embed(item_name))
		else
			respond(interaction, Embeds.market_disambiguation_embed(item_name, candidates))
		end
	end

	defp candidate_name(candidate), do: Embeds.candidate_name(candidate)

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
				embed = Embeds.market_embed(item, nil, "attachment://#{filename}")
				edit_response(bot_name, interaction, %{embeds: [embed], files: [%{name: filename, body: png}]})

			{:error, {:browser_missing, _path}} ->
				edit_fallback_response(bot_name, interaction, item)

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
		embed = Embeds.market_embed(item, nil, "attachment://#{filename}")

		edit_response(bot_name, interaction, %{
			embeds: [embed],
			files: [%{name: filename, body: Janice.Capture.fallback_image()}]
		})
	rescue
		_ -> edit_response(bot_name, interaction, %{embeds: [Embeds.market_embed(item)]})
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
				Embeds.market_list_message(safe_get_items())
			rescue
				_ -> Embeds.market_list_message([])
			catch
				_, _ -> Embeds.market_list_message([])
			end

		edit_response(bot_name, interaction, payload)
	rescue
		_ ->
			try_edit_empty_list(bot_name, interaction)
	catch
		_, _ -> try_edit_empty_list(bot_name, interaction)
	end

	defp try_edit_empty_list(bot_name, interaction) do
		edit_response(bot_name, interaction, Embeds.market_list_message([]))
	rescue
		error -> log_discord_warning("list_market_fallback_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("list_market_fallback_failed", reason, interaction)
	end

	defp list_defer_fallback(interaction, reason) do
		log_discord_warning("list_market_defer_failed", reason, interaction)

		try do
			respond(interaction, Embeds.market_list_message(safe_get_items()))
		rescue
			error -> log_discord_warning("list_market_defer_fallback_failed", Exception.message(error), interaction)
		catch
			_, fallback_reason -> log_discord_warning("list_market_defer_fallback_failed", fallback_reason, interaction)
		end
	end

	defp start_stats_task(bot_name, interaction) do
		task =
			Task.Supervisor.start_child(Marketmailer.TaskSup, fn ->
				run_stats_task(bot_name, interaction)
			end)

		case task do
			{:ok, _pid} ->
				:ok

			{:error, reason} ->
				log_discord_warning("database_stats_task_failed", reason, interaction)
				edit_response(bot_name, interaction, stats_payload(interaction))
		end
	rescue
		error ->
			log_discord_warning("database_stats_task_failed", Exception.message(error), interaction)
			edit_response(bot_name, interaction, stats_payload(interaction))
	catch
		_, reason ->
			log_discord_warning("database_stats_task_failed", reason, interaction)
			edit_response(bot_name, interaction, stats_payload(interaction))
	end

	defp run_stats_task(bot_name, interaction) do
		edit_response(bot_name, interaction, stats_payload(interaction))
	rescue
		_ -> edit_response(bot_name, interaction, Embeds.database_stats_error_embed())
	catch
		_, _ -> edit_response(bot_name, interaction, Embeds.database_stats_error_embed())
	end

	defp stats_defer_fallback(interaction, reason) do
		log_discord_warning("database_stats_defer_failed", reason, interaction)

		try do
			respond(interaction, stats_payload(interaction))
		rescue
			error -> log_discord_warning("database_stats_defer_fallback_failed", Exception.message(error), interaction)
		catch
			_, fallback_reason -> log_discord_warning("database_stats_defer_fallback_failed", fallback_reason, interaction)
		end
	end

	defp stats_payload(interaction) do
		case Marketmailer.Stats.stats() do
			{:ok, stats} -> Embeds.database_stats_embed(stats)
			{:error, reason} -> stats_unavailable(reason, interaction)
		end
	rescue
		error -> stats_unavailable(Exception.message(error), interaction)
	catch
		_, reason -> stats_unavailable(reason, interaction)
	end

	defp stats_unavailable(reason, interaction) do
		log_discord_warning("database_stats_failed", reason, interaction)
		Embeds.database_stats_error_embed()
	end

	defp list_page_from_custom_id(%{data: %{custom_id: "market_list:page:" <> page}}) do
		case Integer.parse(String.trim(page)) do
			{number, _} -> max(number, 1)
			:error -> 1
		end
	end

	defp list_page_from_custom_id(_), do: 1

	defp contract_page_from_custom_id(%{data: %{custom_id: "contract_list:page:" <> page}}) do
		case Integer.parse(String.trim(page)) do
			{number, _} -> max(number, 1)
			:error -> 1
		end
	end

	defp contract_page_from_custom_id(_), do: 1

	defp start_contracts_task(bot_name, interaction) do
		task =
			Task.Supervisor.start_child(Marketmailer.TaskSup, fn ->
				run_contracts_task(bot_name, interaction)
			end)

		case task do
			{:ok, _pid} ->
				:ok

			{:error, reason} ->
				log_discord_warning("contracts_task_failed", reason, interaction)
				edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
		end
	rescue
		error ->
			log_discord_warning("contracts_task_failed", Exception.message(error), interaction)
			edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	catch
		_, reason ->
			log_discord_warning("contracts_task_failed", reason, interaction)
			edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	end

	defp run_contracts_task(bot_name, interaction) do
		payload =
			try do
				Contracts.Broadcast.command_payload()
			rescue
				_ -> Embeds.contract_list_error_payload()
			catch
				_, _ -> Embeds.contract_list_error_payload()
			end

		edit_response(bot_name, interaction, payload)
	rescue
		_ -> edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	catch
		_, _ -> edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	end

	defp contracts_defer_fallback(interaction, reason) do
		log_discord_warning("contracts_defer_failed", reason, interaction)

		try do
			respond_with_contracts(interaction)
		rescue
			error -> log_discord_warning("contracts_defer_fallback_failed", Exception.message(error), interaction)
		catch
			_, fallback_reason -> log_discord_warning("contracts_defer_fallback_failed", fallback_reason, interaction)
		end
	end

	defp start_contracts_page_task(bot_name, interaction) do
		task =
			Task.Supervisor.start_child(Marketmailer.TaskSup, fn ->
				run_contracts_page_task(bot_name, interaction)
			end)

		case task do
			{:ok, _pid} ->
				:ok

			{:error, reason} ->
				log_discord_warning("contracts_page_task_failed", reason, interaction)
				edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
		end
	rescue
		error ->
			log_discord_warning("contracts_page_task_failed", Exception.message(error), interaction)
			edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	catch
		_, reason ->
			log_discord_warning("contracts_page_task_failed", reason, interaction)
			edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	end

	defp run_contracts_page_task(bot_name, interaction) do
		payload =
			try do
				Contracts.Broadcast.page_payload(contract_page_from_custom_id(interaction))
			rescue
				_ -> Embeds.contract_list_error_payload()
			catch
				_, _ -> Embeds.contract_list_error_payload()
			end

		edit_response(bot_name, interaction, payload)
	rescue
		_ -> edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	catch
		_, _ -> edit_response(bot_name, interaction, Embeds.contract_list_error_payload())
	end

	defp respond_with_contracts(interaction) do
		payload =
			try do
				Contracts.Broadcast.command_payload()
			rescue
				_ -> Embeds.contract_list_error_payload()
			catch
				_, _ -> Embeds.contract_list_error_payload()
			end

		case Api.Interaction.create_response(interaction, %{type: 4, data: payload}) do
			:ok -> :ok
			{:error, reason} -> log_discord_warning("contracts_respond_failed", reason, interaction)
		end
	rescue
		error -> log_discord_warning("contracts_respond_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("contracts_respond_failed", reason, interaction)
	end

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
		payload = Embeds.payload(payload)

		Bot.with_bot(bot_name, fn -> Api.Interaction.edit_response(interaction, payload) end)
		|> case do
			:ok -> :ok
			{:ok, _message} -> :ok
			{:error, reason} -> log_discord_warning("interaction_edit_failed", reason, interaction)
			other -> log_discord_warning("interaction_edit_failed", other, interaction)
		end
	rescue
		error -> log_discord_warning("interaction_edit_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("interaction_edit_failed", reason, interaction)
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
			%{
				interaction_id: interaction.id,
				command: interaction_command(interaction),
				reason: inspect(reason)
			},
			"Discord market response failed"
		)
	end

	defp interaction_command(%{data: %{name: name}}) when is_binary(name), do: name
	defp interaction_command(_interaction), do: nil

	defp respond(intr, payload) do
		payload = Embeds.payload(payload)

		case Api.Interaction.create_response(intr, %{type: 4, data: payload}) do
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
	alias Discord.Embeds
	alias Marketmailer.RegionManager
	alias Nostrum.Api
	alias Nostrum.Bot

	@seen_limit 10_000
	@round_timeout_ms 600_000

	def start_link(opts \\ []) do
		name = Keyword.get(opts, :name, __MODULE__)
		GenServer.start_link(__MODULE__, opts, name: name)
	end

	@impl true
	def init(opts) do
		regions = Keyword.get(opts, :regions, Marketmailer.RegionManagerSupervisor.region_ids())
		Enum.each(regions, &subscribe_region/1)
		ESI.Maintenance.subscribe(self())

		state = %{
			async: Keyword.get(opts, :async, true),
			task_supervisor: Keyword.get(opts, :task_supervisor, Marketmailer.TaskSup),
			channels_fun: Keyword.get(opts, :channels_fun, :default),
			market_fun: Keyword.get(opts, :market_fun, :default),
			deliver_fun: Keyword.get(opts, :deliver_fun, :default),
			prune_fun: Keyword.get(opts, :prune_fun, :default),
			regions: regions,
			round: Keyword.get(opts, :round, 1),
			reports: %{},
			seen: MapSet.new(),
			esi_down: ESI.Maintenance.window_open?(),
			round_timeout: Keyword.get(opts, :round_timeout, @round_timeout_ms),
			round_timer: nil
		}

		{:ok, state}
	end

	@impl true
	def code_change(_vsn, state, _extra) when is_map(state) do
		state =
			state
			|> Map.drop([:pending, :round_timer])
			|> Map.merge(%{
				regions: Map.get(state, :regions, Marketmailer.RegionManagerSupervisor.region_ids()),
				round: Map.get(state, :round, 1),
				reports: %{},
				seen: Map.get(state, :seen, MapSet.new()),
				esi_down: Map.get(state, :esi_down, ESI.Maintenance.window_open?()),
				round_timeout: Map.get(state, :round_timeout, @round_timeout_ms),
				round_timer: nil
			})
			|> Map.new(fn
				{key, fun} when key in [:channels_fun, :market_fun, :deliver_fun, :prune_fun] and is_function(fun) ->
					{key, :default}

				{k, v} ->
					{k, v}
			end)

		{:ok, state}
	end

	@impl true
	def handle_info({:region_refresh_complete, summary}, state) do
		record_report(summary, :complete, state)
	end

	def handle_info({:region_refresh_unchanged, summary}, state) do
		record_report(summary, :unchanged, state)
	end

	def handle_info({:region_refresh_failed, summary}, state) do
		record_report(
			summary,
			{:failed, Map.get(summary, :failures, []), Map.get(summary, :updated_pages, [])},
			state
		)
	end

	def handle_info({:broadcast_done, _key, result}, state) do
		case result do
			{:ok, _value} -> :ok
			{:error, reason} -> log_broadcast_failure("broadcast_failed", reason)
		end

		{:noreply, state}
	end

	def handle_info({:esi_maintenance, :down, _info}, %{esi_down: false} = state) do
		state = %{state | esi_down: true}
		payload = %{embeds: [Embeds.esi_down_embed()], components: []}
		deliver_lifecycle(state, %{round: state.round}, "esi_down", payload)
	end

	@min_uptime_ms 5_000

	def handle_info({:esi_maintenance, :up, info}, %{esi_down: true} = state) do
		state = %{state | esi_down: false}

		if Map.get(info, :downtime_ms, 0) < @min_uptime_ms do
			{:noreply, state}
		else
			payload = %{embeds: [Embeds.esi_up_embed(Map.get(info, :downtime_ms))], components: []}
			deliver_lifecycle(state, %{round: state.round}, "esi_up", payload)
		end
	end

	def handle_info({:esi_maintenance, _status, _info}, state), do: {:noreply, state}

	def handle_info({:round_deadline, round}, %{round: round} = state), do: stall_round(state)
	def handle_info({:round_deadline, _round}, state), do: {:noreply, state}

	def handle_info(_message, state), do: {:noreply, state}

	@impl true
	def handle_cast(message, state), do: handle_info(message, state)

	defp subscribe_region(region) do
		RegionManager.subscribe(region, self())
		:ok
	catch
		:exit, reason ->
			Marketmailer.Log.warning(
				"broadcaster_subscribe_failed",
				%{region: region, reason: inspect(reason)},
				"Market broadcaster could not subscribe to region #{region}"
			)

			:ok
	end

	defp record_report(summary, outcome, state) do
		region = Map.get(summary, :region)
		cycle_id = Map.get(summary, :cycle_id)
		key = {region, cycle_id}

		cond do
			state.regions != [] and region not in state.regions ->
				{:noreply, state}

			MapSet.member?(state.seen, key) ->
				{:noreply, state}

			true ->
				state = note_seen(state, key)
				state = if map_size(state.reports) == 0, do: arm_round_deadline(state), else: state
				state = %{state | reports: Map.put(state.reports, region, {cycle_id, outcome})}

				if Enum.all?(state.regions, &Map.has_key?(state.reports, &1)) do
					close_round(state)
				else
					{:noreply, state}
				end
		end
	end

	defp arm_round_deadline(state) do
		cancel_timer(state.round_timer)

		%{
			state
			| round_timer: Process.send_after(self(), {:round_deadline, state.round}, state.round_timeout)
		}
	end

	defp stall_round(state) do
		missing = Enum.reject(state.regions, &Map.has_key?(state.reports, &1))

		Marketmailer.Log.warning(
			"round_stalled",
			%{round: state.round, reported: map_size(state.reports), missing: length(missing)},
			"Round #{state.round} stalled: #{length(missing)} region(s) never reported"
		)

		reports =
			Map.new(missing, fn region ->
				{region, {nil, {:failed, [%{page: nil, reason: :no_report}], []}}}
			end)

		snapshot = %{round: state.round, reports: Map.merge(state.reports, reports), pending: missing}
		state = %{state | round: state.round + 1, reports: %{}, round_timer: nil}

		cond do
			missing == [] ->
				{:noreply, state}

			ESI.Maintenance.window_open?() ->
				Marketmailer.Log.info(
					"broadcast_suppressed",
					%{round: snapshot.round, reason: "esi_maintenance"},
					"Round #{snapshot.round} stalled during an ESI maintenance window"
				)

				{:noreply, state}

			true ->
				deliver_lifecycle(state, snapshot, "round_stalled", error_payload(snapshot))
		end
	end

	defp close_round(state) do
		cancel_timer(state.round_timer)
		snapshot = %{round: state.round, reports: state.reports, pending: []}
		state = %{state | round: state.round + 1, reports: %{}, round_timer: nil}
		log_round_closed(snapshot)

		if state.async do
			start_async_digest(state, snapshot)
		else
			case safely_process_digest(snapshot, state) do
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
		if maintenance_suppressed?(snapshot) do
			Marketmailer.Log.info(
				"broadcast_suppressed",
				%{round: snapshot.round, reason: "esi_maintenance"},
				"Round #{snapshot.round}: ESI maintenance warning already announced"
			)

			{:ok, :maintenance}
		else
			{kind, payload} = digest_message(snapshot, state)
			deliver(snapshot, kind, payload, state)
		end
	end

	defp digest_message(snapshot, state) do
		cond do
			esi_down?(snapshot) ->
				{:esi_down, warning_payload(snapshot)}

			any_updated?(snapshot.reports) ->
				items = fetch_market_list(state)
				failures = digest_failures(snapshot.reports)
				{:market_list, digest_payload(items, failures)}

			true ->
				{:no_update, error_payload(snapshot)}
		end
	end

	defp maintenance_suppressed?(snapshot), do: esi_down?(snapshot) and ESI.Maintenance.window_open?()

	defp deliver(snapshot, kind, payload, state) do
		case fetch_channels(state) do
			{:ok, []} ->
				Marketmailer.Log.info(
					"broadcast_no_channels",
					%{round: snapshot.round},
					"Round #{snapshot.round} closed with no registered channels"
				)

				{:ok, :no_channels}

			{:ok, channels} ->
				result = deliver_all(channels, payload, state)
				log_delivery(snapshot, kind, payload, result)
				result

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp deliver_lifecycle(state, snapshot, kind, payload) do
		if state.async do
			owner = self()

			case Task.Supervisor.start_child(state.task_supervisor, fn ->
						 result = safely_deliver(snapshot, kind, payload, state)
						 send(owner, {:broadcast_done, kind, result})
					 end) do
				{:ok, _pid} ->
					{:noreply, state}

				{:error, reason} ->
					log_broadcast_failure("broadcast_task_failed", reason)
					{:noreply, state}
			end
		else
			case safely_deliver(snapshot, kind, payload, state) do
				{:ok, _value} -> :ok
				{:error, reason} -> log_broadcast_failure("broadcast_failed", reason)
			end

			{:noreply, state}
		end
	end

	defp safely_deliver(snapshot, kind, payload, state) do
		deliver(snapshot, kind, payload, state)
	rescue
		error -> {:error, Exception.message(error)}
	catch
		:exit, reason -> {:error, inspect(reason)}
	end

	defp cancel_timer(nil), do: :ok
	defp cancel_timer(ref), do: Process.cancel_timer(ref)

	defp log_round_closed(snapshot) do
		reports = Map.get(snapshot, :reports, %{})
		counts = round_outcomes(reports)

		Marketmailer.Log.info(
			"round_closed",
			%{
				round: snapshot.round,
				regions: map_size(reports),
				updated: counts.updated,
				unchanged: counts.unchanged,
				failed: counts.failed
			},
			"Round #{snapshot.round} closed across #{map_size(reports)} regions"
		)
	end

	defp outcome_kind({_region, {_cycle, :complete}}), do: :updated
	defp outcome_kind({_region, {_cycle, :unchanged}}), do: :unchanged
	defp outcome_kind({_region, {_cycle, {:failed, _reasons, [_ | _]}}}), do: :updated
	defp outcome_kind({_region, {_cycle, {:failed, _reasons, _updated}}}), do: :failed
	defp outcome_kind(_report), do: :ignored

	defp round_outcomes(reports) do
		counts = reports |> Enum.map(&outcome_kind/1) |> Enum.frequencies()

		Map.merge(
			%{updated: 0, unchanged: 0, failed: 0},
			Map.take(counts, [:updated, :unchanged, :failed])
		)
	end

	defp log_delivery(snapshot, kind, payload, {:ok, delivered}) do
		Marketmailer.Log.info(
			"broadcast_delivered",
			%{
				round: snapshot.round,
				kind: kind,
				channels: delivered,
				embeds: length(Map.get(payload, :embeds, []))
			},
			"Round #{snapshot.round} broadcast #{kind} to #{delivered} channel(s)"
		)
	end

	defp digest_payload(items, failures) do
		base = Embeds.market_list_message(items)

		if failures == %{} do
			base
		else
			%{base | embeds: base.embeds ++ [Embeds.round_status_embed(failures, [])]}
		end
	end

	defp warning_payload(_snapshot) do
		%{embeds: [Embeds.esi_down_embed()], components: []}
	end

	defp error_payload(snapshot) do
		failures = digest_failures(Map.get(snapshot, :reports, %{}))

		embeds =
			if failures == %{} do
				[Embeds.no_update_embed()]
			else
				[Embeds.no_update_embed(failures), Embeds.round_status_embed(failures, [])]
			end

		%{embeds: embeds, components: []}
	end

	defp esi_down?(snapshot) do
		reports = Map.get(snapshot, :reports, %{})
		failures = digest_failures(reports)

		cond do
			any_updated?(reports) -> false
			failures == %{} -> false
			true -> esi_failures_only?(reports)
		end
	end

	defp esi_failures_only?(reports) when map_size(reports) == 0, do: false

	defp esi_failures_only?(reports) do
		failures = digest_failures(reports)

		if failures == %{} or any_updated?(reports) do
			false
		else
			failures
			|> Enum.flat_map(fn {_region, reasons} -> List.wrap(reasons) end)
			|> Enum.map(fn
				%{reason: reason} -> reason
				reason -> reason
			end)
			|> Enum.all?(&down_reason?/1)
		end
	end

	defp down_reason?(:service_unavailable), do: true
	defp down_reason?(status) when status in [420, 500, 502, 503, 504], do: true
	defp down_reason?(_), do: false

	defp any_updated?(reports), do: Enum.any?(reports, &(outcome_kind(&1) == :updated))

	defp digest_failures(reports) do
		for {region, {_cycle_id, outcome}} <- reports,
				reasons = failed_reasons(outcome),
				not is_nil(reasons),
				into: %{} do
			{region, reasons}
		end
	end

	defp failed_reasons({:failed, reasons, _updated}), do: reasons
	defp failed_reasons(_), do: nil

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

		Enum.reduce(channels, {:ok, 0}, fn channel, {:ok, delivered} ->
			case invoke_resolve(state, :deliver_fun, {__MODULE__, :deliver, [channel, message]}) do
				{:ok, _response} ->
					{:ok, delivered + 1}

				{:error, reason} ->
					if unknown_channel?(reason) do
						prune_bad_channel(state, channel, reason)
					else
						log_broadcast_failure("channel_send_failed", reason)
					end

					{:ok, delivered}
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
