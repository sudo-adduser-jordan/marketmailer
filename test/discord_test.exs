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

	test "broadcasts the market list", %{task_supervisor: _task_supervisor} do
	end

	test "broadcasts the contract list", %{task_supervisor: _task_supervisor} do
	end

	test "broadcasts an ESI-down warning", %{task_supervisor: _task_supervisor} do
	end

	test "does nothing when no channels are registered", %{task_supervisor: _task_supervisor} do
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

	test "placeholder image, janice error graph, and janice graph all are the same size" do
	end

	test "messages do not get stuck thinking" do
	end

	test "messages are mobile first" do
	end

	test "labels with its type_id instead of '?' " do
	end

	test "messages contain title" do
	end

	test "messages contain body" do
	end

	test "messages contain footer" do
	end

	test "all embeds carry a SemVer version badge in the footer" do
	end

	test "list paginates with pages and buttons" do
	end

	test "market embeds use the Jita IV-4 station icon" do
	end
end
