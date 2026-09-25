defmodule Discord.Broadcaster do
	@moduledoc """
	Listens for completed market refreshes and sends embeds to registered channels.
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
			 market_fun: Keyword.get(opts, :market_fun, &Market.Database.get_best_order/0),
			 capture_fun: Keyword.get(opts, :capture_fun, &Janice.Capture.capture/1),
			 deliver_fun: Keyword.get(opts, :deliver_fun, &deliver/2),
			 pending: MapSet.new(),
			 seen: MapSet.new()
		 }}
	end

	@impl true
	def handle_info({:region_refresh_complete, summary}, state) do
		start_refresh(summary, :success, state)
	end

	def handle_info({:region_refresh_failed, summary}, state) do
		start_refresh(summary, :failure, state)
	end

	def handle_info({:broadcast_done, key, result}, state) do
		{:noreply, complete_refresh(state, key, result)}
	end

	def handle_info(_message, state), do: {:noreply, state}

	@impl true
	def handle_cast(message, state), do: handle_info(message, state)

	defp start_refresh(summary, kind, state) do
		key = {Map.get(summary, :region), Map.get(summary, :cycle_id)}

		if MapSet.member?(state.pending, key) or MapSet.member?(state.seen, key) do
			{:noreply, state}
		else
			state = %{state | pending: MapSet.put(state.pending, key)}

			if state.async do
				start_async_refresh(state, key, summary, kind)
			else
				result = safely_process_refresh(summary, kind, state)
				{:noreply, complete_refresh(state, key, result)}
			end
		end
	end

	defp start_async_refresh(state, key, summary, kind) do
		owner = self()

		case Task.Supervisor.start_child(state.task_supervisor, fn ->
					 result = safely_process_refresh(summary, kind, state)
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

	defp safely_process_refresh(summary, kind, state) do
		process_refresh(summary, kind, state)
	rescue
		error -> {:error, Exception.message(error)}
	catch
		:exit, reason -> {:error, inspect(reason)}
	end

	defp process_refresh(summary, :success, state) do
		case fetch_channels(state) do
			{:ok, []} ->
				{:ok, :no_channels}

			{:ok, channels} ->
				case fetch_market_item(state) do
					{:ok, item} ->
						{embed, file} = success_payload(item, state)
						deliver_all(channels, embed, file, state)

					{:error, :no_market_item} ->
						failure_all(channels, summary, :no_market_item, state)

					{:error, reason} ->
						failure_all(channels, summary, reason, state)
				end

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp process_refresh(summary, :failure, state) do
		case fetch_channels(state) do
			{:ok, []} -> {:ok, :no_channels}
			{:ok, channels} -> failure_all(channels, summary, :refresh_failed, state)
			{:error, reason} -> {:error, reason}
		end
	end

	defp fetch_channels(state) do
		case invoke(state.channels_fun) do
			{:ok, channels} when is_list(channels) -> {:ok, channels}
			{:ok, _other} -> {:error, :invalid_channels}
			{:error, reason} -> {:error, reason}
		end
	end

	defp fetch_market_item(state) do
		case invoke(state.market_fun) do
			{:ok, [item | _]} -> {:ok, item}
			{:ok, []} -> {:error, :no_market_item}
			{:ok, _other} -> {:error, :invalid_market_result}
			{:error, reason} -> {:error, reason}
		end
	end

	defp success_payload(item, state) do
		case invoke(fn -> state.capture_fun.(item.type_id) end) do
			{:ok, {:ok, png}} when is_binary(png) ->
				filename = Janice.Capture.filename(item.type_id)
				{Messages.market_embed(item, "attachment://#{filename}"), %{name: filename, body: png}}

			{:ok, _other} ->
				{Messages.market_embed(item), nil}

			{:error, reason} ->
				capture_failure(item, reason)
		end
	end

	defp capture_failure(item, reason) do
		Marketmailer.Log.warning(
			"janice_broadcast_capture_failed",
			%{type_id: item.type_id, reason: inspect(reason)},
			"Broadcast chart capture failed; using the static market thumbnail"
		)

		{Messages.market_embed(item), nil}
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
					log_broadcast_failure("channel_send_failed", reason)
					{:error, reason}
			end
		end)
	end

	defp failure_all(channels, summary, reason, state) do
		embed = Messages.market_update_failed_embed(summary, reason)
		deliver_all(channels, embed, nil, state)
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
end
