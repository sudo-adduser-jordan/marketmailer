defmodule Discord.BroadcasterTest do
	use ExUnit.Case, async: false

	import ExUnit.CaptureLog

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)
		:ets.delete(:esi_error_state, :maintenance_mode)

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

	test "broadcasts the list_market command's paginated message", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		region = 97_000_020

		items =
			for i <- 1..25 do
				%{item: "Item #{i}", margin: 1.0, system_name: "Jita", security_status: 0.9}
			end

		_broadcaster =
			start_broadcaster([region], [400], items, fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(region, :updated)

		assert_receive {:sent, 400, payload}
		expected = Discord.Embeds.market_list_message(items)
		assert [embed] = payload.embeds
		assert [expected_embed] = expected.embeds

		assert embed.title == "Items undercutting the Jita buy wall (1/3)"
		assert embed.title == expected_embed.title
		assert embed.description == expected_embed.description
		assert embed.description |> String.split("\n") |> length() == 10

		assert payload.components == expected.components
		assert [%{components: [prev, next]}] = payload.components
		assert prev.custom_id == "market_list:page:0" and prev.disabled
		assert next.custom_id == "market_list:page:2" and not next.disabled
	end

	test "broadcasts an ESI-down warning when the refresh fails on ESI errors", %{
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
		Marketmailer.RegionManager.page_result(region, 1, :failed, %{pages: 1, reason: :service_unavailable})

		assert_receive {:sent, 300, payload}
		assert [warning] = payload.embeds
		assert warning.title == "ESI is down"
		assert warning.description == "Market data is stale; ESI appears to be down."
	end

	test "a local timeout is not ESI down", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		region = 97_000_041

		_broadcaster =
			start_broadcaster([region], [310], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		Marketmailer.RegionManager.page_started(region, 1)
		Marketmailer.RegionManager.page_result(region, 1, :failed, %{pages: 1, reason: :timeout})

		assert_receive {:sent, 310, payload}
		assert [error | _] = payload.embeds
		assert error.title == "No market updates"
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

	test "broadcasts an ESI-down warning when every region reports unavailable", %{
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
				end
			)

		Marketmailer.RegionManager.page_started(reporter, 1)
		Marketmailer.RegionManager.page_result(reporter, 1, :failed, %{pages: 1, reason: :service_unavailable})
		Marketmailer.RegionManager.page_started(stalled, 1)
		Marketmailer.RegionManager.page_result(stalled, 1, :failed, %{pages: 1, reason: :service_unavailable})

		assert_receive {:sent, 1200, payload}, 1_000
		assert [warning] = payload.embeds
		assert warning.title == "ESI is down"
		assert warning.description == "Market data is stale; ESI appears to be down."
	end

	test "broadcasts list plus status when one region updates and another fails locally", %{
		task_supervisor: _task_supervisor
	} do
		test_pid = self()
		changed = 97_000_036
		broken = 97_000_037

		_broadcaster =
			start_broadcaster([changed, broken], [1500], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(changed, :updated)
		Marketmailer.RegionManager.page_started(broken, 1)
		Marketmailer.RegionManager.page_result(broken, 1, :failed, %{pages: 1, reason: :persist_failed})

		assert_receive {:sent, 1500, payload}
		assert [list_embed, status_embed] = payload.embeds
		assert list_embed.description =~ "Tritanium"
		assert status_embed.title == "Market cycle status"
		assert status_embed.description =~ "#{broken}"
	end

	test "broadcasts error-only when no region updates", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		first = 97_000_038
		second = 97_000_039

		_broadcaster =
			start_broadcaster([first, second], [1600], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		complete_cycle(first, :not_modified)
		complete_cycle(second, :not_modified)

		assert_receive {:sent, 1600, payload}
		assert [error] = payload.embeds
		assert error.title == "No market updates"
		refute error.description =~ "Tritanium"
	end

	test "production defaults store no funs in state" do
		{:ok, state} = Discord.Broadcaster.init(regions: [])

		for key <- [:channels_fun, :market_fun, :deliver_fun, :prune_fun] do
			assert Map.get(state, key) == :default
		end

		assert state.reports == %{}
		assert is_integer(state.round)
		refute Map.has_key?(state, :pending)
	end

	test "code_change migrates old state to the barrier shape", %{task_supervisor: task_supervisor} do
		old_state = %{
			async: false,
			task_supervisor: task_supervisor,
			channels_fun: fn -> [1300] end,
			market_fun: fn -> market_list() end,
			deliver_fun: fn _channel, _payload -> {:ok, :sent} end,
			prune_fun: fn _channel -> :ok end,
			pending: MapSet.new([{97_000_036, 123}]),
			seen: MapSet.new()
		}

		assert {:ok, migrated} = Discord.Broadcaster.code_change("0.1.18", old_state, [])

		for key <- [:channels_fun, :market_fun, :deliver_fun, :prune_fun] do
			assert Map.get(migrated, key) == :default
		end

		assert migrated.reports == %{}
		assert is_integer(migrated.round)
		assert is_list(migrated.regions)
		refute Map.has_key?(migrated, :pending)
	end

	@tag :capture_log
	test "logs the closed round and the delivered broadcast", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		region = 97_000_050

		_broadcaster =
			start_broadcaster([region], [1_200], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		log =
			capture_log(fn ->
				complete_cycle(region, :updated)
				assert_receive {:sent, 1_200, _payload}
				# `broadcast_delivered` is logged right after delivery returns
				Process.sleep(50)
			end)

		assert log =~ "round_closed"
		assert log =~ "broadcast_delivered"
	end

	@tag :capture_log
	test "logs a closed round with no channels", %{task_supervisor: _task_supervisor} do
		region = 97_000_051

		_broadcaster =
			start_broadcaster([region], [], market_list(), fn _channel, _payload ->
				flunk("delivery should not be called")
			end)

		log =
			capture_log(fn ->
				complete_cycle(region, :updated)
				Process.sleep(100)
			end)

		assert log =~ "round_closed"
		assert log =~ "broadcast_no_channels"
	end

	@tag :capture_log
	test "logs partial delivery with the delivered count", %{task_supervisor: _task_supervisor} do
		region = 97_000_053

		_broadcaster =
			start_broadcaster([region], [1_300, 1_301], market_list(), fn
				1_300, _payload -> {:ok, :sent}
				_other, _payload -> {:error, {:discord_error, 500}}
			end)

		log =
			capture_log(fn ->
				complete_cycle(region, :updated)
				Process.sleep(100)
			end)

		assert log =~ "broadcast_delivered"
		assert log =~ "channels: 1"
		assert log =~ "channel_send_failed"
	end

	@tag :capture_log
	test "counts a partially updated region as updated", %{task_supervisor: _task_supervisor} do
		test_pid = self()
		region = 97_000_054

		_broadcaster =
			start_broadcaster([region], [1_400], market_list(), fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end)

		log =
			capture_log(fn ->
				Marketmailer.RegionManager.page_started(region, 1)
				Marketmailer.RegionManager.page_started(region, 2)
				Marketmailer.RegionManager.page_result(region, 1, :updated, %{pages: 2})
				Marketmailer.RegionManager.page_result(region, 2, :failed, %{reason: :service_unavailable})
				assert_receive {:sent, 1_400, _payload}
				Process.sleep(50)
			end)

		assert log =~ "updated: 1"
		assert log =~ "failed: 0"
	end

	@tag :capture_log
	test "warns when a region has no manager to subscribe to" do
		region = 97_000_052
		name = :"broadcaster_#{System.unique_integer([:positive])}"

		log =
			capture_log(fn ->
				start_supervised!(
					{Discord.Broadcaster, [name: name, regions: [region], async: false, channels_fun: fn -> [] end]}
				)

				Process.sleep(50)
			end)

		assert log =~ "broadcaster_subscribe_failed"
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

defmodule Discord.EmbedsTest do
	use ExUnit.Case, async: true

	alias MarketView
	alias Nostrum.Struct.Embed

	test "renders a market-not-found failure embed" do
		embed = Discord.Embeds.market_not_found_embed("  Rifter  ")

		assert %Embed{title: "Item not found"} = embed
		assert embed.description == "No cached market order was found for **Rifter**."
	end

	test "explains why a capital hull is excluded from the buy wall" do
		embed = Discord.Embeds.capital_ship_embed("  Rorqual  ")

		assert %Embed{title: "Not tradable in high sec"} = embed
		assert embed.description =~ "**Rorqual**"
		assert embed.description =~ "cannot enter high security space"
		assert embed.color == 0xFAA61A
	end

	test "uses location, sell, buy and margin fields for a market embed" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			location_name: "Jita IV - Moon 4",
			security_status: 0.9,
			price: 10.0,
			buy_price: 110.0
		}

		embed = Discord.Embeds.market_embed(item)
		fields = Map.new(embed.fields, &{&1.name, &1.value})

		assert %Embed{title: "Tritanium"} = embed
		assert %Embed.Author{name: "\u200B", icon_url: broadcast} = embed.author
		assert broadcast =~ "broadcast.png"
		assert fields["Location"] == "Jita IV - Moon 4 - Jita - The Forge • 0.9"
		assert fields["Sell"] == "10.00 ISK"
		assert fields["Buy"] == "110.00 ISK"
		assert fields["Margin"] == "+100.00 ISK"
		assert embed.description =~ "janice.e-351.com/i/1001/market/2"
		assert embed.description =~ "[Janice](https://janice.e-351.com/i/1001/market/2)"
		assert embed.description =~ "[Eve Ref](https://everef.net/types/1001)"
		assert embed.description =~ "[Eve Tycoon](https://evetycoon.com/market/1001)"

		assert embed.description ==
						 "[Janice](https://janice.e-351.com/i/1001/market/2)\n[Eve Ref](https://everef.net/types/1001)\n[Eve Tycoon](https://evetycoon.com/market/1001)"

		lines = embed.description |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

		assert lines == [
						 "[Janice](https://janice.e-351.com/i/1001/market/2)",
						 "[Eve Ref](https://everef.net/types/1001)",
						 "[Eve Tycoon](https://evetycoon.com/market/1001)"
					 ]

		assert embed.color == 0x43B581
	end

	test "signals loss red and unknown margin neutral without code blocks" do
		loss = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			price: 120.0,
			buy_price: 110.0
		}

		loss_embed = Discord.Embeds.market_embed(loss)
		loss_fields = Map.new(loss_embed.fields, &{&1.name, &1.value})

		assert loss_fields["Margin"] == "-10.00 ISK"
		assert loss_embed.color == 0xF04747

		unknown = %MarketView{type_id: 1_001, item_name: "Tritanium", price: 10.0}

		unknown_embed = Discord.Embeds.market_embed(unknown)
		unknown_fields = Map.new(unknown_embed.fields, &{&1.name, &1.value})

		assert unknown_fields["Buy"] == "? ISK"
		assert unknown_fields["Margin"] == "? ISK"
		assert unknown_fields["Location"] == "? - ? - ? • ?"
		assert unknown_embed.color == 0x7289DA
	end

	test "compacts sell, buy and margin to millions at/above 1M" do
		item = %MarketView{
			type_id: 44_992,
			item_name: "PLEX",
			price: 4_660_000.0,
			buy_price: 4_849_000.0
		}

		embed = Discord.Embeds.market_embed(item)
		fields = Map.new(embed.fields, &{&1.name, &1.value})

		assert fields["Sell"] == "4.66M ISK"
		assert fields["Buy"] == "4.85M ISK"
		assert fields["Margin"] == "+189000.00 ISK"

		big = %MarketView{type_id: 1_001, item_name: "Tritanium", price: 10.0, buy_price: 2_000_010.0}
		big_fields = big |> Discord.Embeds.market_embed() |> Map.get(:fields) |> Map.new(&{&1.name, &1.value})

		assert big_fields["Margin"] == "+2.00M ISK"
	end

	test "places the Janice graph in the image slot, keeping the item icon" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0
		}

		embed = Discord.Embeds.market_embed(item, nil, "attachment://janice-1001.png")

		assert embed.image.url == "attachment://janice-1001.png"
		assert embed.thumbnail.url == "https://images.evetech.net/types/1001/icon?size=64"
	end

	test "defaults the thumbnail to the item's EVE image-server icon" do
		item = %MarketView{
			type_id: 81_008,
			item_name: "Squall",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0
		}

		embed = Discord.Embeds.market_embed(item)

		assert embed.thumbnail.url == "https://images.evetech.net/types/81008/icon?size=64"
	end

	test "list embed never crashes on nil, non-list, or string-keyed rows" do
		assert Discord.Embeds.market_list_embed(nil).description =~ "No items"
		assert Discord.Embeds.market_list_embed(:boom).description =~ "No items"

		embed =
			Discord.Embeds.market_list_embed([
				%{
					"item" => "Tritanium",
					"sell_price" => "10",
					"buy_price" => 110.0,
					"margin" => 100.0,
					"location_name" => "Jita IV"
				},
				%{item: "Plex", sell_price: nil, buy_price: nil, margin: nil, system_name: "Jita"}
			])

		assert embed.description =~ "Tritanium"
		assert embed.description =~ "Plex"
	end

	test "list embed renders plain mobile-friendly rows with no code blocks" do
		embed =
			Discord.Embeds.market_list_embed([
				%{item: "Tritanium", margin: 1_250.5, system_name: "Jita", security_status: 0.9},
				%{item: "Plex", margin: nil, system_name: nil, security_status: nil}
			])

		description = embed.description
		refute String.contains?(description, "```")
		refute String.contains?(description, "|")
		refute String.contains?(description, "\e[")

		rows = description |> String.split("\n") |> Enum.reject(&(&1 == ""))
		assert length(rows) == 2
		assert hd(rows) == "**Tritanium** • +1.3k • Jita • 0.9"
		assert List.last(rows) == "**Plex** • ? • ? • ?"
	end

	test "labels an unnamed item with its type id instead of a bare question mark" do
		embed =
			Discord.Embeds.market_list_embed([
				%{
					type_id: 97_265,
					margin: 111_300_000.0,
					system_name: "Larryn",
					security_status: 0.6
				}
			])

		assert embed.description == "**Type 97265** • +111.3M • Larryn • 0.6"
	end

	test "disambiguation embed lists candidates with a re-run hint" do
		embed =
			Discord.Embeds.market_disambiguation_embed("trit", [
				%{item_name: "Tritanium"},
				%{item_name: "Tritanium Blueprint"}
			])

		assert embed.title == "Multiple items found"
		assert embed.description =~ "Multiple items match **trit**:"
		assert embed.description =~ "1. **Tritanium**"
		assert embed.description =~ "2. **Tritanium Blueprint**"
		assert embed.description =~ "Re-run `/check_market` with the exact name."
	end

	test "disambiguation embed falls back when nothing matches" do
		embed = Discord.Embeds.market_disambiguation_embed("zzz", [])

		assert embed.title == "Multiple items found"
		assert embed.description =~ "No cached market order was found for **zzz**."
	end

	test "keeps station-system-region order with the security value" do
		base = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			location_name: "Jita IV - Moon 4",
			price: 10.0
		}

		high = Discord.Embeds.market_embed(%{base | security_status: 0.9})
		low = Discord.Embeds.market_embed(%{base | security_status: 0.3})
		null = Discord.Embeds.market_embed(%{base | security_status: -0.5})

		fields = fn embed -> Map.new(embed.fields, &{&1.name, &1.value}) end

		assert fields.(high)["Location"] ==
						 "Jita IV - Moon 4 - Jita - The Forge • 0.9"

		assert fields.(low)["Location"] ==
						 "Jita IV - Moon 4 - Jita - The Forge • 0.3"

		assert fields.(null)["Location"] ==
						 "Jita IV - Moon 4 - Jita - The Forge • -0.5"
	end

	test "all embeds carry a SemVer version badge in the footer" do
		item = %MarketView{
			type_id: 1_001,
			item_name: "Tritanium",
			region_name: "The Forge",
			system_name: "Jita",
			security_status: 0.0,
			price: 10.0,
			instant_sell_profit: nil
		}

		embeds = [
			Discord.Embeds.server_only(%{}),
			Discord.Embeds.error(%{}),
			Discord.Embeds.market_not_found_embed("Rifter"),
			Discord.Embeds.market_list_embed([]),
			Discord.Embeds.market_embed(item),
			Discord.Embeds.add_channel(%{channel_id: 123}),
			Discord.Embeds.channel_removed(%{channel_id: 123}),
			Discord.Embeds.list_channel(%{channel_id: 123}),
			Discord.Embeds.list_channel(nil),
			Discord.Embeds.esi_down_embed(),
			Discord.Embeds.no_update_embed(),
			Discord.Embeds.database_stats_embed(%{}),
			Discord.Embeds.database_stats_error_embed()
		]

		assert length(embeds) == 13

		for embed <- embeds do
			assert %Embed{footer: %Embed.Footer{text: text}, timestamp: nil} = embed
			assert text =~ ~r/^.+ • v\d+\.\d+\.\d+$/
		end
	end

	test "channel embeds share the corrected Registration title" do
		assert Discord.Embeds.add_channel(%{channel_id: 123}).title == "Channel Registration"
		assert Discord.Embeds.channel_removed(%{channel_id: 123}).title == "Channel Registration"
		assert Discord.Embeds.list_channel(%{channel_id: 123}).title == "Channel Registration"
	end

	test "list payload paginates with clamped pages and nav buttons" do
		items =
			for i <- 1..25 do
				%{item: "Item #{i}", margin: 1.0, system_name: "Jita", security_status: 0.9}
			end

		first = Discord.Embeds.market_list_payload(items, 1, 10)
		assert hd(first.embeds).title == "Items undercutting the Jita buy wall (1/3)"
		assert [%{components: [prev, next]}] = first.components
		assert prev.label == "Prev" and prev.disabled == true and prev.custom_id == "market_list:page:0"
		assert next.label == "Next" and next.disabled == false and next.custom_id == "market_list:page:2"

		clamped = Discord.Embeds.market_list_payload(items, 99, 10)
		assert hd(clamped.embeds).title == "Items undercutting the Jita buy wall (3/3)"

		single = Discord.Embeds.market_list_payload(Enum.take(items, 5), 1, 10)
		assert hd(single.embeds).title == "Items undercutting the Jita buy wall"
		assert single.components == []
	end

	test "market_list_message renders the command page, not one 100-row page" do
		items =
			for i <- 1..100 do
				%{item: "Item #{i}", margin: 1.0, system_name: "Jita", security_status: 0.9}
			end

		message = Discord.Embeds.market_list_message(items)

		assert [embed] = message.embeds
		assert embed.title == "Items undercutting the Jita buy wall (1/10)"
		assert embed.description |> String.split("\n") |> length() == 10
		refute embed.description =~ "more"

		command = Discord.Embeds.market_list_payload(items, 1, Discord.Embeds.list_per_page())
		assert [command_embed] = command.embeds
		assert embed.title == command_embed.title
		assert embed.description == command_embed.description
		assert message.components == command.components
	end

	test "a page too wide for the description limit reports the dropped rows" do
		items =
			for i <- 1..100 do
				%{item: "VeryLongItemName#{i}", margin: 1_000_000.0, system_name: "Somewhere", security_status: 0.4}
			end

		embed = Discord.Embeds.market_list_embed(items, 1, 100)

		assert [last_line | _] = embed.description |> String.split("\n") |> Enum.reverse()
		assert last_line =~ ~r/^… \+\d+ more$/
	end

	# A bare %Embed{} reaches Discord as {"type": "rich", ...} with no embeds key,
	# which the API rejects with 400 50006 "Cannot send an empty message" — the
	# deferred /database_stats reply then stays on "Bot is thinking..." forever.
	test "payload wraps a bare embed and passes map payloads through" do
		stats = Discord.Embeds.database_stats_embed(%{})
		assert %{embeds: [^stats]} = Discord.Embeds.payload(stats)

		error = Discord.Embeds.database_stats_error_embed()
		assert %{embeds: [^error]} = Discord.Embeds.payload(error)

		message = Discord.Embeds.market_list_message([])
		assert Discord.Embeds.payload(message) == message

		chart = %{embeds: [stats], files: [%{name: "chart.png", body: "png"}]}
		assert Discord.Embeds.payload(chart) == chart
	end

	test "a wrapped embed survives Nostrum's request body builder" do
		embed = Discord.Embeds.database_stats_embed(%{})
		payload = Discord.Embeds.payload(embed)

		# combine_embeds/1 only knows the singular :embed key, so an unwrapped
		# %Embed{} would fall through untouched and ship as the whole body.
		assert %{embeds: [^embed]} = Nostrum.Api.Helpers.combine_embeds(payload)
		refute Nostrum.Api.Helpers.combine_embeds(embed) |> Map.has_key?(:embeds)
	end

	test "market embeds use the Jita IV-4 station icon, not Squall" do
		items = [%{item: "Tritanium", margin: 1.0, system_name: "Jita", security_status: 0.9}]

		for embed <- [
					Discord.Embeds.market_list_embed(items, 1, 10),
					Discord.Embeds.round_status_embed(%{}, []),
					Discord.Embeds.esi_down_embed(),
					Discord.Embeds.no_update_embed()
				] do
			assert embed.thumbnail.url == "https://images.evetech.net/types/52678/icon?size=64"
			refute embed.thumbnail.url =~ "81008"
		end
	end

	test "database stats embed renders every section" do
		stats = %{
			order_count: 1_868_361,
			sell_orders: 1_378_574,
			buy_orders: 489_787,
			tracked_types: 19_544,
			tracked_systems: 1_719,
			jita_buy_types: 17_806,
			undercut_rows: 47_231,
			known_names: 31_800,
			known_systems: 8_490,
			etag_pages: 1_638,
			alert_channels: 1,
			unnamed_locations: 263_972,
			unknown_systems: 0,
			contract_count: 12_345,
			contract_items_count: 1_234_567,
			contract_regions: 70,
			contracts_resolved: 11_900,
			contracts_pending: 445,
			contracts_failed: 120,
			contract_last_seen_round: 4_242,
			contract_page_workers: 42,
			contract_active_round: 4_243,
			contract_top_round: 4_242,
			contract_last_desired: 87,
			last_write_at: "2026-10-17T01:34:03",
			first_write_at: "2026-10-01T03:19:12",
			schema_version: 20_261_019_000_000,
			page_count: 176_182,
			page_size: 4_096,
			journal_mode: "wal",
			query_ms: 840,
			page_workers: 42,
			regions: 115,
			uptime_seconds: 190_800,
			sde_build: "3569502",
			cache_entries: 1_638,
			esi_error_entries: 0,
			esi_rate_entries: 2,
			janice_cache_entries: 0
		}

		embed = Discord.Embeds.database_stats_embed(stats)
		fields = Map.new(embed.fields, &{&1.name, &1.value})

		assert embed.title == "Database Statistics"
		assert embed.author.icon_url =~ "broadcast.png"
		assert embed.thumbnail.url =~ "database.png"
		assert embed.color == 0x7289DA

		assert Map.keys(fields) |> Enum.sort() ==
						 ["Contracts", "Coverage", "Freshness", "Order cache", "Poller", "Storage", "Undercut list"]

		assert fields["Order cache"] =~ "Orders: **1,868,361**"
		assert fields["Order cache"] =~ "Sell / buy: 1,378,574 / 489,787"
		assert fields["Order cache"] =~ "Types: 19,544"
		assert fields["Order cache"] =~ "Systems: 1,719"

		assert fields["Storage"] =~ "Size: **688.2 MB**"
		assert fields["Storage"] =~ "Journal: wal"
		assert fields["Storage"] =~ "Schema: 20261019000000"
		assert fields["Storage"] =~ "Oldest order: Oct 01, 2026 03:19 UTC"

		assert fields["Freshness"] =~ "Last write: **"
		assert fields["Freshness"] =~ "ago**"
		assert fields["Freshness"] =~ "Query: 840 ms"

		assert fields["Contracts"] =~ "Cached: **12,345** across 70 regions • 1,234,567 item rows"
		assert fields["Contracts"] =~ "Items: resolved 11,900 • pending 445 • failed 120"
		assert fields["Contracts"] =~ "Workers: 42 • round: running"
		assert fields["Contracts"] =~ "last complete #4,242 • desired 87 • seen #4,242"

		assert fields["Undercut list"] =~ "47,231 orders undercut the Jita buy wall"
		assert fields["Undercut list"] =~ "`/list_market` shows the top 100"
		assert fields["Undercut list"] =~ "Jita buy-wall types: 17,806"

		assert fields["Coverage"] =~ "Names: 31,800 / systems: 8,490"
		assert fields["Coverage"] =~ "Types with orders: 19,544 of 31,800 known names"
		assert fields["Coverage"] =~ "Unnamed locations: 263,972 (14.1% of orders)"
		assert fields["Coverage"] =~ "Unknown systems: 0"

		assert fields["Poller"] =~ "Regions: 115 • page workers: 42"
		assert fields["Poller"] =~ "Etag pages: 1,638 • ETS cache: 1,638"
		assert fields["Poller"] =~ "0 error-state, 2 rate-state, 0 chart"
		assert fields["Poller"] =~ "Alert channels: 1 • VM uptime: 2d 5h"
		assert fields["Poller"] =~ "SDE build: 3569502"

		for {_name, value} <- fields, do: refute(value =~ "nil")
	end

	test "database stats embed survives nil, empty and unknown stats" do
		for stats <- [nil, %{}, :boom, "oops"] do
			embed = Discord.Embeds.database_stats_embed(stats)
			fields = Map.new(embed.fields, &{&1.name, &1.value})

			assert embed.title == "Database Statistics"
			assert map_size(fields) == 7
			assert fields["Order cache"] =~ "Orders: **0**"
			assert fields["Storage"] =~ "Size: **?**"
			assert fields["Freshness"] =~ "Last write: **never**"
			assert fields["Contracts"] =~ "Cached: **0** across 0 regions • 0 item rows"
			assert fields["Contracts"] =~ "round: idle • last complete none • desired 0 • seen none"
			assert fields["Undercut list"] =~ "0 orders undercut"
			assert fields["Coverage"] =~ "Unknown systems: 0"
			assert fields["Poller"] =~ "SDE build: ?"

			for {_name, value} <- fields do
				refute value =~ "nil"
				assert is_binary(value) and value != ""
			end
		end
	end

	test "database stats error embed names the failed read" do
		embed = Discord.Embeds.database_stats_error_embed()

		assert embed.title == "Database Statistics"
		assert embed.author.icon_url =~ "failure.png"
		assert embed.thumbnail.url =~ "database.png"
		assert embed.color == 0xF04747
		assert embed.description =~ "could not be read"
		assert %Embed.Footer{text: text} = embed.footer
		assert text =~ ~r/ • v\d+\.\d+\.\d+$/
	end
end
