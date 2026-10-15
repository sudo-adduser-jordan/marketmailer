defmodule Discord.BroadcasterTest do
	use ExUnit.Case, async: false

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)

		# `mix test` boots the app, which already starts Registry
		# (pollers stay disabled via `start_pollers: false`).
		# PageSup is a poller child, so tests provide it when absent.
		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		# Park every PageWorker: with maintenance active no worker calls ESI.
		MarketmailerTest.Fixtures.park_page_workers()

		unique = System.unique_integer([:positive])
		task_supervisor = :"broadcaster_tasks_#{unique}"
		start_supervised!({Task.Supervisor, name: task_supervisor})
		{:ok, task_supervisor: task_supervisor}
	end

	test "broadcasts the undercut list to every channel", %{task_supervisor: task_supervisor} do
		test_pid = self()
		channel_ids = [100, 200]
		region = 97_000_010

		_broadcaster =
			start_broadcaster([region], channel_ids, market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(region, :updated)

		assert_receive {:sent, 100, first_payload}
		assert_receive {:sent, 200, second_payload}
		assert first_payload.allowed_mentions == :none
		assert [embed] = first_payload.embeds
		assert embed.title == "Items undercutting the Jita buy wall"
		assert embed.description =~ "Tritanium"
		refute Map.has_key?(first_payload, :files)
		assert second_payload == first_payload
	end

	test "ignores a failed refresh without notifying Discord", %{task_supervisor: _task_supervisor} do
		region = 97_000_011

		_broadcaster =
			start_broadcaster([region], [300], market_list(), fn channel, payload ->
				send(self(), {:sent, channel, payload})
				{:ok, :sent}
			end)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :failed, %{pages: 1, reason: :timeout})

		refute_receive {:sent, _channel, _payload}, 150
	end

	test "stays silent when the market query has no items", %{task_supervisor: _task_supervisor} do
		region = 97_000_012

		_broadcaster =
			start_broadcaster([region], [400], [], fn channel, payload ->
				send(self(), {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(region, :updated)

		refute_receive {:sent, _channel, _payload}, 150
	end

	test "does nothing when no channels are registered", %{task_supervisor: _task_supervisor} do
		region = 97_000_013

		broadcaster =
			start_broadcaster([region], [], market_list(), fn _channel, _payload ->
				flunk("delivery should not be called")
			end)

		complete_cycle(region, :updated)

		refute_receive {:sent, _channel, _payload}, 150
		assert Process.alive?(broadcaster)
	end

	test "suppresses duplicate events for the same refresh cycle", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		region = 97_000_014

		broadcaster =
			start_broadcaster([region], [500], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		summary = %{region: region, cycle_id: 99, pages: 1, updated_pages: [1]}
		GenServer.cast(broadcaster, {:region_refresh_complete, summary})
		GenServer.cast(broadcaster, {:region_refresh_complete, summary})

		assert_receive {:sent, 500, _payload}
		refute_receive {:sent, 500, _payload}, 150
	end

	test "keeps the broadcaster alive when Discord delivery fails", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		region = 97_000_015

		broadcaster =
			start_broadcaster([region], [600], market_list(), fn channel, _payload ->
				send(test_pid, {:attempted, channel})
				{:error, :forbidden}
			end)

		complete_cycle(region, :updated)

		assert_receive {:attempted, 600}
		assert Process.alive?(broadcaster)
	end

	test "handles a missing Discord bot without crashing", %{task_supervisor: _task_supervisor} do
		region = 97_000_016
		broadcaster = start_broadcaster([region], [700], market_list(), nil)

		complete_cycle(region, :updated)

		assert Process.alive?(broadcaster)
	end

	test "stays silent when the market query returns an invalid shape", %{
		task_supervisor: _task_supervisor
	} do
		region = 97_000_019

		_broadcaster =
			start_broadcaster([region], [900], %{unexpected: :shape}, fn channel, payload ->
				send(self(), {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(region, :updated)

		refute_receive {:sent, _channel, _payload}, 150
	end

	test "keeps the broadcaster alive after an async refresh completes", %{
		task_supervisor: task_supervisor
	} do
		test_pid = self()
		region = 97_000_017

		broadcaster =
			start_broadcaster(
				[region],
				[800],
				market_list(),
				fn channel, _payload ->
					send(test_pid, {:sent, channel})
					{:ok, :sent}
				end,
				async: true,
				task_supervisor: task_supervisor
			)

		complete_cycle(region, :updated)
		assert_receive {:sent, 800}

		complete_cycle(region, :updated)
		assert_receive {:sent, 800}
		assert Process.alive?(broadcaster)
	end

	defp start_broadcaster(regions, channels, market_result, deliver_fun, opts \\ []) do
		Enum.each(regions, &start_cycle_manager/1)

		name = :"broadcaster_#{System.unique_integer([:positive])}"
		deliver_opts = if deliver_fun, do: [deliver_fun: deliver_fun], else: []

		market_fun =
			if is_function(market_result, 0), do: market_result, else: fn -> market_result end

		pid =
			start_supervised!(
				{Discord.Broadcaster,
				 [
					 name: name,
					 regions: regions,
					 async: Keyword.get(opts, :async, false),
					 task_supervisor: Keyword.get(opts, :task_supervisor, Marketmailer.TaskSup),
					 channels_fun: fn -> channels end,
					 market_fun: market_fun
				 ] ++ deliver_opts}
			)

		pid
	end

	defp start_cycle_manager(region) do
		{:ok, manager} = Marketmailer.RegionManager.start_link(region, cycle_timeout: 1_000)

		on_exit(fn ->
			for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, region, 1}) do
				try do
					GenServer.stop(pid, :normal)
				catch
					:exit, _ -> :ok
				end
			end

			try do
				GenServer.stop(manager, :normal)
			catch
				:exit, _ -> :ok
			end
		end)

		manager
	end

	defp complete_cycle(region, status) do
		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, status, %{pages: 1})
	end

	defp market_list do
		[
			%{
				item: "Tritanium",
				sell_price: 10.0,
				buy_price: 110.0,
				margin: 100.0,
				location_name: "Jita IV - Moon 4",
				system_name: "Rens",
				type_id: 1_001
			}
		]
	end
end
