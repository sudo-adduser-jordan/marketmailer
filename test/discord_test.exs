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

defmodule Discord.MessagesTest do
	use ExUnit.Case, async: true

	alias MarketView
	alias Nostrum.Struct.Embed

	test "renders a market-not-found failure embed" do
		embed = Discord.Messages.market_not_found_embed("  Rifter  ")

		assert %Embed{title: "Item not found"} = embed
		assert embed.description == "No cached market order was found for **Rifter**."
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

		embed = Discord.Messages.market_embed(item)
		fields = Map.new(embed.fields, &{&1.name, &1.value})

		assert %Embed{title: "Tritanium"} = embed
		assert embed.author == nil
		assert fields["Location"] == "Jita IV - Moon 4 - Jita - The Forge (0.9)"
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

		loss_embed = Discord.Messages.market_embed(loss)
		loss_fields = Map.new(loss_embed.fields, &{&1.name, &1.value})

		assert loss_fields["Margin"] == "-10.00 ISK"
		assert loss_embed.color == 0xF04747

		unknown = %MarketView{type_id: 1_001, item_name: "Tritanium", price: 10.0}

		unknown_embed = Discord.Messages.market_embed(unknown)
		unknown_fields = Map.new(unknown_embed.fields, &{&1.name, &1.value})

		assert unknown_fields["Buy"] == "? ISK"
		assert unknown_fields["Margin"] == "? ISK"
		assert unknown_fields["Location"] == "? - ? - ? (?)"
		assert unknown_embed.color == 0x7289DA
	end

	test "compacts sell, buy and margin to millions at/above 1M" do
		item = %MarketView{
			type_id: 44_992,
			item_name: "PLEX",
			price: 4_660_000.0,
			buy_price: 4_849_000.0
		}

		embed = Discord.Messages.market_embed(item)
		fields = Map.new(embed.fields, &{&1.name, &1.value})

		assert fields["Sell"] == "4.66M ISK"
		assert fields["Buy"] == "4.85M ISK"
		assert fields["Margin"] == "+189000.00 ISK"

		big = %MarketView{type_id: 1_001, item_name: "Tritanium", price: 10.0, buy_price: 2_000_010.0}
		big_fields = big |> Discord.Messages.market_embed() |> Map.get(:fields) |> Map.new(&{&1.name, &1.value})

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

		embed = Discord.Messages.market_embed(item, nil, "attachment://janice-1001.png")

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

		embed = Discord.Messages.market_embed(item)

		assert embed.thumbnail.url == "https://images.evetech.net/types/81008/icon?size=64"
	end

	test "list embed never crashes on nil, non-list, or string-keyed rows" do
		assert Discord.Messages.market_list_embed(nil).description =~ "No items"
		assert Discord.Messages.market_list_embed(:boom).description =~ "No items"

		embed =
			Discord.Messages.market_list_embed([
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
			Discord.Messages.market_list_embed([
				%{item: "Tritanium", margin: 1_250.5, system_name: "Jita", security_status: 0.9},
				%{item: "Plex", margin: nil, system_name: nil, security_status: nil}
			])

		description = embed.description
		refute String.contains?(description, "```")
		refute String.contains?(description, "|")
		refute String.contains?(description, "\e[")

		rows = description |> String.split("\n") |> Enum.reject(&(&1 == ""))
		assert length(rows) == 2
		assert hd(rows) =~ "Tritanium"
		assert hd(rows) =~ "+1.3k"
		assert hd(rows) =~ "(0.9)"
		assert List.last(rows) =~ "?"
		assert List.last(rows) =~ "(?)"
	end

	test "disambiguation embed lists candidates with a re-run hint" do
		embed =
			Discord.Messages.market_disambiguation_embed("trit", [
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
		embed = Discord.Messages.market_disambiguation_embed("zzz", [])

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

		high = Discord.Messages.market_embed(%{base | security_status: 0.9})
		low = Discord.Messages.market_embed(%{base | security_status: 0.3})
		null = Discord.Messages.market_embed(%{base | security_status: -0.5})

		fields = fn embed -> Map.new(embed.fields, &{&1.name, &1.value}) end

		assert fields.(high)["Location"] ==
						 "Jita IV - Moon 4 - Jita - The Forge (0.9)"

		assert fields.(low)["Location"] ==
						 "Jita IV - Moon 4 - Jita - The Forge (0.3)"

		assert fields.(null)["Location"] ==
						 "Jita IV - Moon 4 - Jita - The Forge (-0.5)"
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
			Discord.Messages.server_only(%{}),
			Discord.Messages.error(%{}),
			Discord.Messages.market_not_found_embed("Rifter"),
			Discord.Messages.market_list_embed([]),
			Discord.Messages.market_embed(item),
			Discord.Messages.add_channel(%{channel_id: 123}),
			Discord.Messages.channel_removed(%{channel_id: 123}),
			Discord.Messages.list_channel(%{channel_id: 123}),
			Discord.Messages.list_channel(nil)
		]

		assert length(embeds) == 9

		for embed <- embeds do
			assert %Embed{footer: %Embed.Footer{text: text}, timestamp: nil} = embed
			assert text =~ ~r/^.+ • v\d+\.\d+\.\d+$/
		end
	end

	test "channel embeds share the corrected Registration title" do
		assert Discord.Messages.add_channel(%{channel_id: 123}).title == "Channel Registration"
		assert Discord.Messages.channel_removed(%{channel_id: 123}).title == "Channel Registration"
		assert Discord.Messages.list_channel(%{channel_id: 123}).title == "Channel Registration"
	end

	test "list payload paginates with clamped pages and nav buttons" do
		items =
			for i <- 1..25 do
				%{item: "Item #{i}", margin: 1.0, system_name: "Jita", security_status: 0.9}
			end

		first = Discord.Messages.market_list_payload(items, 1, 10)
		assert hd(first.embeds).title == "Items undercutting the Jita buy wall (1/3)"
		assert [%{components: [prev, next]}] = first.components
		assert prev.label == "Prev" and prev.disabled == true and prev.custom_id == "market_list:page:0"
		assert next.label == "Next" and next.disabled == false and next.custom_id == "market_list:page:2"

		clamped = Discord.Messages.market_list_payload(items, 99, 10)
		assert hd(clamped.embeds).title == "Items undercutting the Jita buy wall (3/3)"

		single = Discord.Messages.market_list_payload(Enum.take(items, 5), 1, 10)
		assert hd(single.embeds).title == "Items undercutting the Jita buy wall"
		assert single.components == []
	end
end
