defmodule Database.WriterTest do
	use ExUnit.Case, async: false

	import Ecto.Query, only: [from: 2]

	alias Market.Database, as: MarketDatabase

	@base_order_id 70_000_001

	setup do
		on_exit(fn -> Database.delete_all(from(m in "market", where: m.order_id >= @base_order_id)) end)
		:ok
	end

	test "write executes the fun in the caller process" do
		test_pid = self()

		assert Database.Writer.write(fn ->
						 send(test_pid, {:ran, self()})
						 :ok
					 end) == :ok

		assert_receive {:ran, caller}
		assert caller == test_pid
	end

	test "a burst of page writes all succeeds with no timeouts" do
		pages = 150
		rows_per_page = 1000

		{elapsed_ms, results} =
			:timer.tc(fn ->
				1..pages
				|> Task.async_stream(
					fn page ->
						first = @base_order_id + (page - 1) * rows_per_page
						MarketDatabase.upsert_orders(page_fixture(first, rows_per_page))
					end,
					max_concurrency: pages,
					timeout: 60_000
				)
				|> Enum.to_list()
			end)
			|> then(fn {us, results} -> {div(us, 1000), results} end)

		assert length(results) == pages

		for {:ok, count} <- results do
			assert count == rows_per_page
		end

		assert elapsed_ms < 20_000
	end

	defp page_fixture(first_order_id, count) do
		for i <- 0..(count - 1) do
			%{
				"order_id" => first_order_id + i,
				"duration" => 90,
				"is_buy_order" => rem(i, 2) == 0,
				"issued" => "2026-10-15T00:00:00",
				"location_id" => 60_000_001,
				"min_volume" => 1,
				"price" => 10.5,
				"range" => "region",
				"system_id" => 30_000_001,
				"type_id" => 34,
				"volume_remain" => 100,
				"volume_total" => 1000
			}
		end
	end
end
