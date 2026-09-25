defmodule Discord.BroadcasterTest do
	use ExUnit.Case, async: false

	alias MarketView

	setup do
		unique = System.unique_integer([:positive])
		coordinator = :"broadcaster_coordinator_#{unique}"
		task_supervisor = :"broadcaster_tasks_#{unique}"
		start_supervised!({Market.UpdateCoordinator, name: coordinator, cycle_timeout: 1_000})
		start_supervised!({Task.Supervisor, name: task_supervisor})
		{:ok, coordinator: coordinator, task_supervisor: task_supervisor}
	end

	test "broadcasts a successful market embed with an attachment to every channel", %{coordinator: coordinator} do
		test_pid = self()
		channel_ids = [100, 200]

		broadcaster =
			start_broadcaster(coordinator, channel_ids, market_item(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(coordinator, 10, :updated)

		assert_receive {:sent, 100, first_payload}
		assert_receive {:sent, 200, second_payload}
		assert first_payload.allowed_mentions == :none
		assert [embed] = first_payload.embeds
		assert embed.thumbnail.url == "attachment://janice-1001.png"
		assert [%{name: "janice-1001.png", body: <<137, 80, 78, 71>>}] = first_payload.files
		assert second_payload == first_payload
		assert Process.alive?(broadcaster)
	end

	test "broadcasts a failure embed for a failed refresh", %{coordinator: coordinator} do
		test_pid = self()

		_broadcaster =
			start_broadcaster(coordinator, [300], market_item(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		Market.UpdateCoordinator.page_started(11, 1, coordinator)
		Market.UpdateCoordinator.page_result(11, 1, :failed, %{pages: 1, reason: :timeout}, coordinator)

		assert_receive {:sent, 300, payload}
		assert payload.allowed_mentions == :none
		assert [embed] = payload.embeds
		assert embed.title == "Market update failed"
		assert embed.description =~ "Region 11"
		assert embed.description =~ "timeout"
		refute Map.has_key?(payload, :files)
	end

	test "sends a failure embed when the market query has no item", %{coordinator: coordinator} do
		test_pid = self()

		_broadcaster =
			start_broadcaster(coordinator, [400], [], fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(coordinator, 12, :updated)

		assert_receive {:sent, 400, payload}
		assert [embed] = payload.embeds
		assert embed.title == "Market update failed"
		assert embed.description =~ "no_market_item"
	end

	test "does nothing when no channels are registered", %{coordinator: coordinator} do
		broadcaster =
			start_broadcaster(coordinator, [], market_item(), fn _channel, _payload ->
				flunk("delivery should not be called")
			end)

		complete_cycle(coordinator, 13, :updated)

		refute_receive {:sent, _channel, _payload}, 150
		assert Process.alive?(broadcaster)
	end

	test "suppresses duplicate events for the same refresh cycle", %{coordinator: coordinator} do
		test_pid = self()

		broadcaster =
			start_broadcaster(coordinator, [500], market_item(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		summary = %{region: 14, cycle_id: 99, pages: 1, updated_pages: [1]}
		GenServer.cast(broadcaster, {:region_refresh_complete, summary})
		GenServer.cast(broadcaster, {:region_refresh_complete, summary})

		assert_receive {:sent, 500, _payload}
		refute_receive {:sent, 500, _payload}, 150
	end

	test "keeps the broadcaster alive when Discord delivery fails", %{coordinator: coordinator} do
		test_pid = self()

		broadcaster =
			start_broadcaster(coordinator, [600], market_item(), fn channel, _payload ->
				send(test_pid, {:attempted, channel})
				{:error, :forbidden}
			end)

		complete_cycle(coordinator, 15, :updated)

		assert_receive {:attempted, 600}
		assert Process.alive?(broadcaster)
	end

	test "handles a missing Discord bot without crashing", %{coordinator: coordinator} do
		broadcaster = start_broadcaster(coordinator, [700], market_item(), nil)

		complete_cycle(coordinator, 16, :updated)

		assert Process.alive?(broadcaster)
	end

	test "keeps the broadcaster alive after an async refresh completes", %{
		coordinator: coordinator,
		task_supervisor: task_supervisor
	} do
		test_pid = self()

		broadcaster =
			start_broadcaster(
				coordinator,
				[800],
				market_item(),
				fn channel, _payload ->
					send(test_pid, {:sent, channel})
					{:ok, :sent}
				end,
				async: true,
				task_supervisor: task_supervisor
			)

		complete_cycle(coordinator, 17, :updated)
		assert_receive {:sent, 800}

		complete_cycle(coordinator, 18, :updated)
		assert_receive {:sent, 800}
		assert Process.alive?(broadcaster)
	end

	defp start_broadcaster(coordinator, channels, market_result, deliver_fun, opts \\ []) do
		name = :"broadcaster_#{System.unique_integer([:positive])}"
		deliver_opts = if deliver_fun, do: [deliver_fun: deliver_fun], else: []

		pid =
			start_supervised!(
				{Discord.Broadcaster,
				 [
					 name: name,
					 coordinator: coordinator,
					 async: Keyword.get(opts, :async, false),
					 task_supervisor: Keyword.get(opts, :task_supervisor, Marketmailer.TaskSup),
					 channels_fun: fn -> channels end,
					 market_fun: fn -> market_result end,
					 capture_fun: fn _type_id -> {:ok, <<137, 80, 78, 71>>} end
				 ] ++ deliver_opts}
			)

		pid
	end

	defp complete_cycle(coordinator, region, status) do
		Market.UpdateCoordinator.page_started(region, 1, coordinator)
		Market.UpdateCoordinator.page_result(region, 1, status, %{pages: 1}, coordinator)
	end

	defp market_item do
		[
			%MarketView{
				type_id: 1_001,
				item_name: "Tritanium",
				region_name: "The Forge",
				system_name: "Jita",
				security_status: 0.0,
				price: 10.0
			}
		]
	end
end
