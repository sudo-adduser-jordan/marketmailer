defmodule Discord.Broadcaster do
	@moduledoc """
	Listens for completed market refreshes and broadcasts the undercut list
	to registered channels. Failed refreshes are log-only (the coordinator
	already emits a `region_refresh_failed` warning to `logs/errors.jsonl`);
	nothing is sent to Discord for them so one flaky page cannot spam every
	channel.
	"""

	use GenServer

	alias Discord.Database, as: DiscordDatabase
	alias Discord.Messages
	alias Market.UpdateCoordinator
	alias Nostrum.Api
	alias Nostrum.Bot

	@seen_limit 10_000

	def start_link(opts \\ []) do
		name = Keyword.get(opts, :name, __MODULE__)
		GenServer.start_link(__MODULE__, opts, name: name)
	end

	@impl true
	def init(opts) do
		coordinator = Keyword.get(opts, :coordinator, UpdateCoordinator)
		:ok = UpdateCoordinator.subscribe(self(), coordinator)

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

	# Failures are intentionally log-only: UpdateCoordinator already logs
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
