defmodule Discord.BroadcasterTest do
	use ExUnit.Case, async: false

	import ExUnit.CaptureLog

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.ensure_ets(:market_cache)
		MarketmailerTest.Fixtures.reset_esi_maintenance()

		if !Process.whereis(Marketmailer.Registry) do
			start_supervised!({Registry, keys: :unique, name: Marketmailer.Registry})
		end

		if !Process.whereis(Marketmailer.PageSup) do
			start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup})
		end

		MarketmailerTest.Fixtures.park_page_workers()

		# The cycle managers started below spawn a real page-1 worker each;
		# with zero start jitter in test it would fetch live ESI and close the
		# single-region round with a stray digest mid-test. A downed watchdog
		# parks workers on their recheck loop so only synthetic reports land.
		MarketmailerTest.Fixtures.network_down()

		on_exit(fn ->
			MarketmailerTest.Fixtures.reset_esi_maintenance()
			MarketmailerTest.Fixtures.reset_network()
		end)

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
		assert embed.author.name == "Jita buy wall (1/1)"
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
			:persistent_term.erase({Contracts, :top_contracts})
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
				volume_remain: 2_000_000,
				volume_total: 2_000_000,
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
		assert embed.author.name == "Contracts (1/1)"
		assert embed.description =~ "Contract 1001"
		assert embed.description =~ "200.0m"
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

	test "announces the ESI maintenance window with a down and an up embed", %{
		task_supervisor: task_supervisor
	} do
		Application.put_env(:marketmailer, :esi_maintenance,
			announce_grace_ms: 0,
			close_grace_ms: 0
		)

		on_exit(fn -> Application.delete_env(:marketmailer, :esi_maintenance) end)

		test_pid = self()
		region = 97_000_050

		broadcaster =
			start_broadcaster(
				[region],
				[300],
				market_list(),
				fn _channel, payload ->
					send(test_pid, {:sent, payload})
					{:ok, :sent}
				end,
				task_supervisor: task_supervisor,
				cycle_timeout: 10_000
			)

		# No round closes during a maintenance window, so the embed cannot wait for one.
		ESI.Maintenance.down(%{status: 503, url: "https://esi.evetech.net/v1/markets/1/orders/"})

		assert_receive {:sent, down_payload}, 1_000
		assert [down] = down_payload.embeds
		assert down.title == "ESI is down"
		assert down.color == 0xFAA61A

		ESI.Maintenance.down(%{status: 502, url: "https://esi.evetech.net/v1/markets/1/orders/"})
		refute_receive {:sent, _payload}, 200

		# The window only lived ~200ms, so the close is announced by
		# maintenance but swallowed by the broadcaster's 5s floor: no "0s"
		# outage embed.
		ESI.Maintenance.up()
		refute_receive {:sent, _payload}, 300

		# A genuine recovery still announces.
		send(broadcaster, {:esi_maintenance, :down, %{since_ms: 1, reason: "HTTP 503"}})
		assert_receive {:sent, _down_again}, 1_000

		send(broadcaster, {:esi_maintenance, :up, %{downtime_ms: 6_000}})

		assert_receive {:sent, up_payload}, 1_000
		assert [up] = up_payload.embeds
		assert up.title == "ESI is back"
		assert up.color == 0x43B581
		assert up.description =~ "Polling resumed"

		ESI.Maintenance.up()
		refute_receive {:sent, _payload}, 200
	end

	test "suppresses ESI-up embeds for sub-threshold windows", %{task_supervisor: task_supervisor} do
		test_pid = self()
		region = 97_000_055

		broadcaster =
			start_broadcaster(
				[region],
				[300],
				market_list(),
				fn _channel, payload ->
					send(test_pid, {:sent, payload})
					{:ok, :sent}
				end,
				task_supervisor: task_supervisor,
				cycle_timeout: 10_000
			)

		send(broadcaster, {:esi_maintenance, :down, %{since_ms: 1, reason: "HTTP 503"}})
		assert_receive {:sent, down_payload}, 1_000
		assert [down] = down_payload.embeds
		assert down.title == "ESI is down"

		# A 0s flap flips the flag back without a green embed.
		send(broadcaster, {:esi_maintenance, :up, %{downtime_ms: 100}})
		refute_receive {:sent, _payload}, 300

		send(broadcaster, {:esi_maintenance, :down, %{since_ms: 2, reason: "HTTP 503"}})
		assert_receive {:sent, _down_again}, 1_000

		send(broadcaster, {:esi_maintenance, :up, %{downtime_ms: 6_000}})
		assert_receive {:sent, up_payload}, 1_000
		assert [up] = up_payload.embeds
		assert up.title == "ESI is back"
		assert up.description =~ "6s"
	end

	test "closes a stalled round instead of staying silent", %{task_supervisor: task_supervisor} do
		test_pid = self()
		first = 97_000_060
		second = 97_000_061

		start_broadcaster(
			[first, second],
			[300],
			market_list(),
			fn _channel, payload ->
				send(test_pid, {:sent, payload})
				{:ok, :sent}
			end,
			task_supervisor: task_supervisor,
			round_timeout: 100
		)

		complete_cycle(first, :unchanged)

		assert_receive {:sent, payload}, 1_000
		assert [no_update | _rest] = payload.embeds
		assert no_update.title == "No market updates"
		assert no_update.description =~ "no_report"
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
		cycle_timeout = Keyword.get(opts, :cycle_timeout, 1_000)
		Enum.each(regions, &start_cycle_manager(&1, cycle_timeout))

		name = :"broadcaster_#{System.unique_integer([:positive])}"
		deliver_opts = if deliver_fun, do: [deliver_fun: deliver_fun], else: []

		market_fun =
			if is_function(market_result, 0), do: market_result, else: fn -> market_result end

		extra =
			case Keyword.fetch(opts, :round_timeout) do
				{:ok, timeout} -> [round_timeout: timeout]
				:error -> []
			end

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
				 ] ++ deliver_opts ++ extra}
			)

		pid
	end

	defp start_cycle_manager(region, cycle_timeout) do
		{:ok, manager} = Marketmailer.RegionManager.start_link(region, cycle_timeout: cycle_timeout)

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
				region_name: "Heimatar",
				type_id: 1_001
			}
		]
	end
end

defmodule Discord.EmbedsTest do
	use ExUnit.Case, async: true

	alias MarketView

	test "placeholder image, janice error graph, and janice graph all are the same size" do
		item = market_item()

		placeholder = Discord.Embeds.market_embed(item)
		assert placeholder.image.url =~ "assets/expansion/background.png"

		error_graph = Discord.Embeds.market_embed(item, nil, "attachment://janice-failed.png")
		assert error_graph.image.url == "attachment://janice-failed.png"

		graph = Discord.Embeds.market_embed(item, nil, "attachment://janice-34.png")
		assert graph.image.url == "attachment://janice-34.png"

		assert {:ok, {width, height}} = Janice.Padding.dimensions(File.read!("assets/expansion/background.png"))
		assert {width, height} == Janice.Capture.image_size()
		assert {:ok, {^width, ^height}} = Janice.Padding.dimensions(Janice.Capture.fallback_image())

		assert {:ok, {^width, ^height}} =
						 chart_png() |> Janice.Padding.fit() |> Janice.Padding.pad() |> Janice.Padding.dimensions()
	end

	test "market embed links to eve market browser" do
		description = Discord.Embeds.market_embed(market_item()).description

		assert description =~ "[Eve Market Browser](https://evemarketbrowser.com/region/0/type/34)"
		refute description =~ "evetycoon"
	end

	test "market embed margin is compact isk plus a percentage" do
		item = %{market_item() | price: 4_990_000.0, buy_price: 4_775_000.0}
		fields = Discord.Embeds.market_embed(item).fields

		assert Enum.find(fields, &(&1.name == "Sell")).value == "4.99m ISK"
		assert Enum.find(fields, &(&1.name == "Buy")).value == "4.78m ISK"
		assert Enum.find(fields, &(&1.name == "Margin")).value == "-215.0k ISK (-4.3%)"
	end

	test "market embed margin falls back to a placeholder without prices" do
		item = %{market_item() | price: nil, buy_price: nil}
		fields = Discord.Embeds.market_embed(item).fields

		assert Enum.find(fields, &(&1.name == "Margin")).value == "? ISK"
	end

	test "messages do not get stuck thinking" do
		embed = Discord.Embeds.market_list_embed(market_list())

		assert Discord.Embeds.payload(embed) == %{embeds: [embed]}
		refute Map.has_key?(Discord.Embeds.payload(embed), :embed)

		payload = %{embeds: [embed], components: []}
		assert Discord.Embeds.payload(payload) == payload
	end

	test "market list lines are item, margin, region" do
		[line] = String.split(Discord.Embeds.market_list_embed(market_list()).description, "\n")

		assert line ==
						 "[**Tritanium**](https://evemarketbrowser.com/region/0/type/34) +100.00 • Heimatar"

		refute line =~ "0.9"
	end

	test "market list region labels keep their first three words" do
		items = [%{item: "Zarmazd", margin: 38_700_000.0, region_name: "Vale of the Silent"}]

		assert Discord.Embeds.market_list_embed(items).description == "**Zarmazd** +38.7m • Vale of the"
	end

	test "market list region falls back to ? without an SDE system" do
		items = [%{item: "Zarmazd", margin: 1.0}]

		assert Discord.Embeds.market_list_embed(items).description == "**Zarmazd** +1.00 • ?"
	end

	test "the ESI up embed is green and names the downtime" do
		embed = Discord.Embeds.esi_up_embed(252_000)

		assert embed.title == "ESI is back"
		assert embed.color == 0x43B581
		assert embed.description =~ "4m 12s"
		assert embed.footer.text =~ "• v"
	end

	test "the ESI down embed stays a yellow warning" do
		embed = Discord.Embeds.esi_down_embed()

		assert embed.title == "ESI is down"
		assert embed.color == 0xFAA61A
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
				region_name: "Heimatar",
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
