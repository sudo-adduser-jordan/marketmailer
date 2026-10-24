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

	test "broadcasts the market list", %{task_supervisor: task_supervisor} do
		test_pid = self()
		region = 97_000_010

		start_broadcaster(
			[region],
			[100, 200],
			market_list(),
			fn channel, payload ->
				send(test_pid, {:sent, channel, payload})
				{:ok, :sent}
			end,
			task_supervisor: task_supervisor
		)

		complete_cycle(region, :updated)

		assert_receive {:sent, 100, first_payload}, 1_000
		assert_receive {:sent, 200, second_payload}, 1_000

		assert first_payload.allowed_mentions == :none
		assert [embed] = first_payload.embeds
		assert embed.title == "Items undercutting the Jita buy wall"
		assert embed.description =~ "Tritanium"
		refute Map.has_key?(first_payload, :files)
		assert second_payload == first_payload
	end

	test "broadcasts the contract list", %{task_supervisor: _task_supervisor} do
		region = 97_000_020

		Database.delete_all("discord")
		Database.delete_all("contract_items")
		Database.delete_all("contracts")
		Database.delete_all("market")
		Database.delete_all("names")

		on_exit(fn ->
			Database.delete_all("contract_items")
			Database.delete_all("contracts")
			Database.delete_all("market")
			Database.delete_all("names")
			:persistent_term.erase({Contracts, :top_round})
			:persistent_term.erase({Contracts, :round_stats})
		end)

		now = Contracts.now_ms()

		Database.insert_all("names", [%{id: 34, name: "Tritanium", is_capital_ship: 0}])

		Database.insert_all("market", [
			%{
				order_id: 1,
				duration: 90,
				is_buy_order: 1,
				issued: DateTime.from_unix!(now, :millisecond) |> DateTime.to_iso8601(),
				location_id: 60_000_001,
				min_volume: 1,
				price: 100.0,
				range: "station",
				system_id: 30_000_142,
				type_id: 34,
				volume_remain: 100,
				volume_total: 100,
				inserted_at: NaiveDateTime.utc_now(:second),
				updated_at: NaiveDateTime.utc_now(:second)
			}
		])

		Database.insert_all("contracts", [
			%{
				contract_id: 1_001,
				region_id: region,
				page: 1,
				type: "item_exchange",
				title: "Contract 1001",
				price: 0.0,
				buyout: nil,
				expires_at: now + 3_600_000,
				issued_at: now,
				start_location_id: 60_000_001,
				items_fetched: 1,
				last_seen_round: 7,
				inserted_at: NaiveDateTime.utc_now(:second),
				updated_at: NaiveDateTime.utc_now(:second)
			}
		])

		Database.insert_all("contract_items", [
			%{
				record_id: 1_001_034,
				contract_id: 1_001,
				type_id: 34,
				quantity: 2_000_000,
				is_included: 1,
				is_blueprint_copy: 0
			}
		])

		results = %{
			region => %{
				region: region,
				round: 7,
				pages: 1,
				updated_pages: [1],
				failures: [],
				item_fetches: 1,
				item_failures: 0,
				dropped: 0
			}
		}

		assert :ok = Contracts.Broadcast.finalize(7, results, Contracts.config(min_margin: 100))
		assert Contracts.Broadcast.current_round() == 7

		payload = Contracts.Broadcast.command_payload()

		assert [embed] = payload.embeds
		assert embed.title == "Contract arbitrage"
		assert embed.description =~ "Contract 1001"
		assert embed.description =~ "200.0m ISK"
		assert embed.description =~ "1 item(s): Tritanium"
	end

	test "broadcasts an ESI-down warning", %{task_supervisor: task_supervisor} do
		test_pid = self()
		region = 97_000_030

		start_broadcaster(
			[region],
			[300],
			market_list(),
			fn _channel, payload ->
				send(test_pid, {:sent, payload})
				{:ok, :sent}
			end,
			task_supervisor: task_supervisor
		)

		Marketmailer.RegionManager.page_started(region, 1)

		Marketmailer.RegionManager.page_result(region, 1, :failed, %{
			pages: 1,
			reason: :service_unavailable
		})

		assert_receive {:sent, payload}, 1_000
		assert [embed] = payload.embeds
		assert embed.title == "ESI is down"
	end

	test "does nothing when no channels are registered", %{task_supervisor: task_supervisor} do
		test_pid = self()
		region = 97_000_040

		start_broadcaster(
			[region],
			[],
			market_list(),
			fn _channel, payload ->
				send(test_pid, {:sent, payload})
				{:ok, :sent}
			end,
			task_supervisor: task_supervisor
		)

		log =
			capture_log(fn ->
				complete_cycle(region, :updated)
				refute_receive {:sent, _payload}, 300
			end)

		assert log =~ "broadcast_no_channels"
	end

	defp start_broadcaster(regions, channels, market_result, deliver_fun, opts) do
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

	test "placeholder image, janice error graph, and janice graph all are the same size" do
		item = market_item()

		placeholder = Discord.Embeds.market_embed(item)
		assert placeholder.image.url =~ "assets/background.png"

		error_graph = Discord.Embeds.market_embed(item, nil, "attachment://janice-failed.png")
		assert error_graph.image.url == "attachment://janice-failed.png"

		graph = Discord.Embeds.market_embed(item, nil, "attachment://janice-34.png")
		assert graph.image.url == "attachment://janice-34.png"

		assert {:ok, {832, 432}} = Janice.Padding.dimensions(Janice.Capture.fallback_image())
		assert {:ok, {832, 432}} = Janice.Padding.dimensions(Janice.Padding.pad(chart_png()))
	end

	test "messages do not get stuck thinking" do
		embed = Discord.Embeds.market_list_embed(market_list())

		assert Discord.Embeds.payload(embed) == %{embeds: [embed]}
		refute Map.has_key?(Discord.Embeds.payload(embed), :embed)

		payload = %{embeds: [embed], components: []}
		assert Discord.Embeds.payload(payload) == payload
	end

	test "messages are mobile first" do
		embed = Discord.Embeds.market_list_embed(market_list())

		assert embed.description == "**Tritanium** • +100.00 • Rens • 0.9"
		refute embed.description =~ "```"
		assert embed.description |> String.split("\n") |> length() == 1
	end

	test "labels with its type_id instead of '?' " do
		unnamed = [
			%{item: nil, item_name: nil, margin: 5.0, system_name: "Jita", security_status: 0.9, type_id: 12_345}
		]

		embed = Discord.Embeds.market_list_embed(unnamed)

		assert embed.description =~ "Type 12345"
		refute embed.description =~ "**?**"

		unknown = [%{item: " ", margin: 5.0, system_name: "Jita", security_status: 0.9}]
		assert Discord.Embeds.market_list_embed(unknown).description =~ "**?**"
	end

	test "messages contain title" do
		items = market_list()

		assert Discord.Embeds.market_list_embed(items).title == "Items undercutting the Jita buy wall"
		assert Discord.Embeds.market_embed(market_item()).title == "Tritanium"
		assert Discord.Embeds.market_list_embed([]).title == "Items undercutting the Jita buy wall"
	end

	test "messages contain body" do
		embed = Discord.Embeds.market_embed(market_item())

		assert embed.description =~ "https://janice.e-351.com/i/34/market/2"
		assert embed.description =~ "https://everef.net/types/34"
		assert embed.description =~ "https://evetycoon.com/market/34"

		fields = Map.new(embed.fields, fn field -> {field.name, field.value} end)

		assert fields["Location"] == "Jita IV - Moon 4 - Jita - The Forge • 0.9"
		assert fields["Sell"] == "10.00 ISK"
		assert fields["Buy"] == "110.00 ISK"
		assert fields["Margin"] == "+100.00 ISK"

		assert Discord.Embeds.market_list_embed([]).description ==
						 "No items are undercutting the Jita buy wall right now."
	end

	test "messages contain footer" do
		embed = Discord.Embeds.market_list_embed(market_list())

		assert is_binary(embed.footer.text)
		assert embed.footer.text =~ " • v"
		assert embed.footer.text =~ ~r/^\w{3} \d{2}, \d{4} \d{2}:\d{2} UTC • v\d+\.\d+\.\d+$/
		assert embed.timestamp == nil
	end

	test "all embeds carry a SemVer version badge in the footer" do
		embeds = [
			Discord.Embeds.server_only(nil),
			Discord.Embeds.error(nil),
			Discord.Embeds.market_not_found_embed("Tritanium"),
			Discord.Embeds.capital_ship_embed("Naglfar"),
			Discord.Embeds.market_disambiguation_embed("trita", [%{item_name: "Tritanium"}]),
			Discord.Embeds.market_list_embed(market_list()),
			Discord.Embeds.market_embed(market_item()),
			Discord.Embeds.round_status_embed(%{}, []),
			Discord.Embeds.esi_down_embed(),
			Discord.Embeds.no_update_embed(),
			Discord.Embeds.add_channel(%{channel_id: 1}),
			Discord.Embeds.channel_removed(%{channel_id: 1}),
			Discord.Embeds.list_channel(nil),
			Discord.Embeds.database_stats_embed(%{}),
			Discord.Embeds.database_stats_error_embed(),
			hd(Discord.Embeds.contract_list_empty_payload("none").embeds),
			hd(Discord.Embeds.contract_list_error_payload().embeds)
		]

		for %Embed{} = embed <- embeds do
			assert embed.footer.text =~ ~r/ • v\d+\.\d+\.\d+$/
			assert embed.timestamp == nil
		end
	end

	test "list paginates with pages and buttons" do
		items =
			for index <- 1..25 do
				%{item: "Item #{index}", margin: 1.0, system_name: "Jita", security_status: 0.9}
			end

		payload = Discord.Embeds.market_list_payload(items, 2, 10)

		assert [embed] = payload.embeds
		assert embed.title == "Items undercutting the Jita buy wall (2/3)"

		lines = String.split(embed.description, "\n")
		assert length(lines) == 10
		assert hd(lines) =~ "Item 11"
		assert List.last(lines) =~ "Item 20"

		assert [%{components: [prev, next]}] = payload.components
		assert prev.label == "Prev"
		assert prev.custom_id == "market_list:page:1"
		assert next.label == "Next"
		assert next.custom_id == "market_list:page:3"
		refute next.disabled

		assert [last_embed] = Discord.Embeds.market_list_payload(items, 99, 10).embeds
		assert last_embed.title == "Items undercutting the Jita buy wall (3/3)"

		assert Discord.Embeds.market_list_payload([], 1, 10).components == []
	end

	test "market embeds use the Jita IV-4 station icon" do
		station_icon = "https://images.evetech.net/types/52678/icon?size=64"

		for embed <- [
					Discord.Embeds.market_list_embed(market_list()),
					Discord.Embeds.esi_down_embed(),
					Discord.Embeds.no_update_embed(),
					Discord.Embeds.round_status_embed(%{}, []),
					Discord.Embeds.error(nil)
				] do
			assert embed.thumbnail.url == station_icon
			refute embed.thumbnail.url =~ "Squall"
		end

		assert Discord.Embeds.market_embed(market_item()).thumbnail.url ==
						 "https://images.evetech.net/types/34/icon?size=64"

		overridden = Discord.Embeds.market_embed(market_item(), "attachment://janice-34.png")
		assert overridden.thumbnail.url == "attachment://janice-34.png"
	end

	test "contract lines carry price, value, margin, items and expiry" do
		config = contracts_config()

		[contract] =
			contracts(1,
				title: "  Capital hull lot  ",
				price: 1_500_000_000.0,
				items_value: 1_750_000_000.0,
				margin: 250_000_000.0,
				has_capital: 1,
				item_names: ["Naglfar", "Fighter"],
				item_count: 2,
				expires_at: Contracts.now_ms() + 7_200_000
			)

		[embed] = Discord.Embeds.contract_list_payload([contract], 1, config).embeds
		description = embed.description

		assert description =~ "**Capital hull lot** [CAPITAL]"
		assert description =~ "The Forge / Jita IV - Moon 4"
		assert description =~ "1.5b ISK → 1.8b ISK (**+250.0m ISK**)"
		assert description =~ "2 item(s): Naglfar, Fighter"
		assert description =~ ~r/• expires \d+h \d+m •/
		assert description =~ "`1001`"
	end

	test "contract list paginates with buttons" do
		config = contracts_config(broadcast_per_page: 2)
		payload = Discord.Embeds.contract_list_payload(contracts(5), 2, config)

		assert [embed] = payload.embeds
		assert embed.title == "Contract arbitrage (2/3)"

		lines = String.split(embed.description, "\n")
		assert length(lines) == 2
		assert hd(lines) =~ "Contract 3"
		assert List.last(lines) =~ "Contract 4"

		assert [%{components: [prev, next]}] = payload.components
		assert prev.label == "Prev"
		assert prev.custom_id == "contract_list:page:1"
		assert next.label == "Next"
		assert next.custom_id == "contract_list:page:3"
		refute next.disabled

		assert [last_embed] = Discord.Embeds.contract_list_payload(contracts(5), 99, config).embeds
		assert last_embed.title == "Contract arbitrage (3/3)"

		empty = Discord.Embeds.contract_list_payload([], 1, config)
		assert [empty_embed] = empty.embeds
		assert empty.components == []
		assert empty_embed.description == "No contracts meet the 100m ISK margin this cycle."
	end

	test "contract list empty and error payloads" do
		empty = Discord.Embeds.contract_list_empty_payload("No contract round has completed yet.")
		assert [empty_embed] = empty.embeds
		assert empty_embed.title == "Contract arbitrage"
		assert empty_embed.description == "No contract round has completed yet."
		assert empty.components == []

		error = Discord.Embeds.contract_list_error_payload()
		assert [error_embed] = error.embeds
		assert error_embed.title == "Contracts unavailable"
		assert error_embed.color == 0xF04747
		assert error.components == []
	end

	defp contracts(count, overrides \\ []) do
		for index <- 1..count do
			%{
				contract_id: 1_000 + index,
				title: "Contract #{index}",
				price: 100_000_000.0,
				buyout: nil,
				has_capital: 0,
				items_value: 300_000_000.0,
				margin: 200_000_000.0,
				item_count: 1,
				item_names: ["Tritanium"],
				region_name: "The Forge",
				location_name: "Jita IV - Moon 4",
				expires_at: Contracts.now_ms() + 3_600_000
			}
			|> Map.merge(Map.new(overrides))
		end
	end

	defp contracts_config(overrides \\ []) do
		Contracts.config(Keyword.merge([broadcast_per_page: 10, broadcast_limit: 100], overrides))
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
				security_status: 0.9,
				type_id: 34
			}
		]
	end

	defp market_item do
		%MarketView{
			type_id: 34,
			item_name: "Tritanium",
			price: 10.0,
			buy_price: 110.0,
			location_name: "Jita IV - Moon 4",
			system_name: "Jita",
			region_name: "The Forge",
			security_status: 0.9
		}
	end

	defp chart_png do
		row = <<0>> <> :binary.copy(<<255, 0, 0>>, 800)
		raw = :binary.copy(row, 400)
		header = <<800::32-big, 400::32-big, 8, 2, 0, 0, 0>>

		<<137, 80, 78, 71, 13, 10, 26, 10>> <>
			chunk("IHDR", header) <> chunk("IDAT", deflate(raw)) <> chunk("IEND", "")
	end

	defp chunk(type, data) do
		<<byte_size(data)::32-big, type::binary, data::binary, :erlang.crc32(type <> data)::32-big>>
	end

	defp deflate(raw) do
		z = :zlib.open()

		try do
			:ok = :zlib.deflateInit(z)
			out = :zlib.deflate(z, raw, :finish) |> IO.iodata_to_binary()
			:ok = :zlib.deflateEnd(z)
			out
		after
			:zlib.close(z)
		end
	end
end
