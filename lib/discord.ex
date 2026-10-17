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

			"list_market" ->
				case active_bot_name() do
					nil ->
						respond(interaction, Embeds.market_list_payload(safe_get_items(), 1, Embeds.list_per_page()))

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
		if is_list(candidates) and candidates != [] do
			respond(interaction, Embeds.market_disambiguation_embed(item_name, candidates))
		else
			respond(interaction, Embeds.market_not_found_embed(item_name))
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
				Embeds.market_list_payload(safe_get_items(), 1, Embeds.list_per_page())
			rescue
				_ -> Embeds.market_list_payload([], 1, Embeds.list_per_page())
			catch
				_, _ -> Embeds.market_list_payload([], 1, Embeds.list_per_page())
			end

		edit_response(bot_name, interaction, payload)
	rescue
		_ ->
			try_edit_empty_list(bot_name, interaction)
	catch
		_, _ -> try_edit_empty_list(bot_name, interaction)
	end

	defp try_edit_empty_list(bot_name, interaction) do
		edit_response(bot_name, interaction, Embeds.market_list_payload([], 1, Embeds.list_per_page()))
	rescue
		error -> log_discord_warning("list_market_fallback_failed", Exception.message(error), interaction)
	catch
		_, reason -> log_discord_warning("list_market_fallback_failed", reason, interaction)
	end

	defp list_defer_fallback(interaction, reason) do
		log_discord_warning("list_market_defer_failed", reason, interaction)

		try do
			respond(interaction, Embeds.market_list_payload(safe_get_items(), 1, Embeds.list_per_page()))
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
	alias Discord.Embeds
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
			seen: MapSet.new()
		}

		{:ok, state}
	end

	@impl true
	def code_change(_vsn, state, _extra) when is_map(state) do
		state =
			state
			|> Map.drop([:pending, :round_timer, :round_timeout])
			|> Map.merge(%{
				regions: Map.get(state, :regions, Marketmailer.RegionManagerSupervisor.region_ids()),
				round: Map.get(state, :round, 1),
				reports: %{},
				seen: Map.get(state, :seen, MapSet.new())
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
			:ok -> :ok
			{:ok, _value} -> :ok
			{:error, reason} -> log_broadcast_failure("broadcast_failed", reason)
		end

		{:noreply, state}
	end

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
				state = %{state | reports: Map.put(state.reports, region, {cycle_id, outcome})}

				if Enum.all?(state.regions, &Map.has_key?(state.reports, &1)) do
					close_round(state)
				else
					{:noreply, state}
				end
		end
	end

	defp close_round(state) do
		snapshot = %{round: state.round, reports: state.reports, pending: []}
		state = %{state | round: state.round + 1, reports: %{}}
		log_round_closed(snapshot)

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
				Marketmailer.Log.info(
					"broadcast_no_channels",
					%{round: snapshot.round},
					"Round #{snapshot.round} closed with no registered channels"
				)

				{:ok, :no_channels}

			{:ok, channels} ->
				{kind, payload} =
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

				result = deliver_all(channels, payload, state)
				log_delivery(snapshot, channels, kind, payload, result)
				result

			{:error, reason} ->
				{:error, reason}
		end
	end

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

	defp round_outcomes(reports) do
		Enum.reduce(reports, %{updated: 0, unchanged: 0, failed: 0}, fn
			{_region, {_cycle, :complete}}, counts -> %{counts | updated: counts.updated + 1}
			{_region, {_cycle, :unchanged}}, counts -> %{counts | unchanged: counts.unchanged + 1}
			{_region, {_cycle, {:failed, _reasons, _updated}}}, counts -> %{counts | failed: counts.failed + 1}
			{_region, {_cycle, {:failed, _reasons}}}, counts -> %{counts | failed: counts.failed + 1}
			_other, counts -> counts
		end)
	end

	defp log_delivery(snapshot, channels, kind, payload, :ok) do
		Marketmailer.Log.info(
			"broadcast_delivered",
			%{
				round: snapshot.round,
				kind: kind,
				channels: length(channels),
				embeds: length(Map.get(payload, :embeds, []))
			},
			"Round #{snapshot.round} broadcast #{kind} to #{length(channels)} channel(s)"
		)
	end

	defp log_delivery(_snapshot, _channels, _kind, _payload, {:error, _reason}), do: :ok

	defp digest_payload(items, failures) do
		base = Embeds.market_list_payload(items, 1, Embeds.list_broadcast_per_page())

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

	defp any_updated?(reports) do
		Enum.any?(reports, fn
			{_region, {_cycle, :complete}} -> true
			{_region, {_cycle, {:failed, _, updated}}} when is_list(updated) -> updated != []
			{_region, {_cycle, {:failed, _}}} -> false
			_ -> false
		end)
	end

	defp digest_failures(reports) do
		for {region, {_cycle_id, outcome}} <- reports,
				reasons = failed_reasons(outcome),
				not is_nil(reasons),
				into: %{} do
			{region, reasons}
		end
	end

	defp failed_reasons({:failed, reasons}), do: reasons
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
