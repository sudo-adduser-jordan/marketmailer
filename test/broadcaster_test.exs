defmodule Discord.BroadcasterTest do
	use ExUnit.Case, async: false

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)

		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		MarketmailerTest.Fixtures.park_page_workers()

		unique = System.unique_integer([:positive])
		task_supervisor = :"broadcaster_tasks_#{unique}"
		start_supervised!({Task.Supervisor, name: task_supervisor})
		{:ok, task_supervisor: task_supervisor}
	end

	test "broadcasts the undercut list to every channel", %{task_supervisor: _task_supervisor} do
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

	test "broadcasts a digest with a status section when a refresh fails", %{
		task_supervisor: _task_supervisor
	} do
		test_pid = self()
		region = 97_000_011

		_broadcaster =
			start_broadcaster([region], [300], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :failed, %{pages: 1, reason: :timeout})

		assert_receive {:sent, 300, payload}
		assert [list_embed, status_embed] = payload.embeds
		assert list_embed.title == "Items undercutting the Jita buy wall"
		assert status_embed.title == "Market cycle status"
		assert status_embed.description =~ "#{region}"
		assert status_embed.description =~ "page 1"
		assert status_embed.description =~ "timeout"
	end

	test "broadcasts the list even when the market query has no items", %{
		task_supervisor: _task_supervisor
	} do
		test_pid = self()
		region = 97_000_012

		_broadcaster =
			start_broadcaster([region], [400], [], fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(region, :updated)

		assert_receive {:sent, 400, payload}
		assert [embed] = payload.embeds
		assert embed.description =~ "No items are undercutting"
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

	test "broadcasts an empty list when the market query returns an invalid shape", %{
		task_supervisor: _task_supervisor
	} do
		test_pid = self()
		region = 97_000_019

		_broadcaster =
			start_broadcaster([region], [900], %{unexpected: :shape}, fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(region, :updated)

		assert_receive {:sent, 900, payload}
		assert [embed] = payload.embeds
		assert embed.description =~ "No items are undercutting"
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

	test "waits for every region before broadcasting the round", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		first = 97_000_030
		second = 97_000_031

		broadcaster =
			start_broadcaster([first, second], [1000], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(first, :updated)
		refute_receive {:sent, _channel, _payload}, 150
		assert Process.alive?(broadcaster)

		complete_cycle(second, :updated)
		assert_receive {:sent, 1000, payload}
		assert [embed] = payload.embeds
		assert embed.description =~ "Tritanium"
		refute_receive {:sent, _channel, _payload}, 150
	end

	test "counts unchanged cycles toward the round", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		changed = 97_000_032
		same = 97_000_033

		_broadcaster =
			start_broadcaster([changed, same], [1100], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(changed, :updated)
		complete_cycle(same, :not_modified)

		assert_receive {:sent, 1100, payload}
		assert [embed] = payload.embeds
		assert embed.description =~ "Tritanium"
	end

	test "ignores reports from unknown regions when closing the round", %{
		task_supervisor: _task_supervisor
	} do
		test_pid = self()
		region = 97_000_040

		broadcaster =
			start_broadcaster([region], [1400], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		GenServer.cast(
			broadcaster,
			{:region_refresh_complete, %{region: 96_000_000, cycle_id: 7, pages: 1, updated_pages: [1]}}
		)

		refute_receive {:sent, _channel, _payload}, 150

		complete_cycle(region, :updated)
		assert_receive {:sent, 1400, _payload}
	end

	test "closes the round on deadline with pending regions listed", %{
		task_supervisor: _task_supervisor
	} do
		test_pid = self()
		reporter = 97_000_034
		stalled = 97_000_035

		_broadcaster =
			start_broadcaster(
				[reporter, stalled],
				[1200],
				market_list(),
				fn channel, payload ->
					send(test_pid, {:sent, channel, payload})
					{:ok, :sent}
				end,
				round_timeout: 100
			)

		complete_cycle(reporter, :updated)

		assert_receive {:sent, 1200, payload}, 1_000
		assert [list_embed, status_embed] = payload.embeds
		assert list_embed.description =~ "Tritanium"
		assert status_embed.title == "Market cycle status"
		assert status_embed.description =~ "#{stalled}"
		assert status_embed.description =~ "awaiting cycle"
	end

	test "production defaults store no funs in state" do
		{:ok, state} = Discord.Broadcaster.init(regions: [], round_timeout: 60_000)

		for key <- [:channels_fun, :market_fun, :deliver_fun, :prune_fun] do
			assert Map.get(state, key) == :default
		end

		assert state.reports == %{}
		assert is_integer(state.round)
		refute Map.has_key?(state, :pending)
	end

	test "code_change migrates legacy state to the barrier shape", %{task_supervisor: task_supervisor} do
		legacy = %{
			async: false,
			task_supervisor: task_supervisor,
			channels_fun: fn -> [1300] end,
			market_fun: fn -> market_list() end,
			deliver_fun: fn _channel, _payload -> {:ok, :sent} end,
			prune_fun: fn _channel -> :ok end,
			pending: MapSet.new([{97_000_036, 123}]),
			seen: MapSet.new()
		}

		assert {:ok, migrated} = Discord.Broadcaster.code_change("0.1.18", legacy, [])

		for key <- [:channels_fun, :market_fun, :deliver_fun, :prune_fun] do
			assert Map.get(migrated, key) == :default
		end

		assert migrated.reports == %{}
		assert is_integer(migrated.round)
		assert is_list(migrated.regions)
		refute Map.has_key?(migrated, :pending)
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
					 market_fun: market_fun,
					 round_timeout: Keyword.get(opts, :round_timeout, 60_000)
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
