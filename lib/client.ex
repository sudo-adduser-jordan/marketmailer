defmodule Marketmailer.Client do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    work()
    schedule_work()
    {:ok, state}
  end

  def handle_info(:work, state) do
    work()
    schedule_work()
    {:noreply, state}
  end

  defp schedule_work do
    Process.send_after(self(), :work, 300_000)
  end

  defp work() do
    # regions = Req.get!("https://esi.evetech.net/v1/universe/regions").body |> IO.inspect()
    regions = [10_000_003]

    orders =
      Task.async_stream(
        regions,
        fn region ->
          IO.inspect(region)
          data_region = Esi.Api.Markets.orders(region, order_type: "all") |> Enum.to_list()
          IO.inspect("#{region} complete")
          data_region
        end, timeout: 300_000)
      |> Enum.flat_map(fn {:ok, result} -> result end)




    #   %{
    #   "duration" => 90,
    #   "is_buy_order" => true,
    #   "issued" => "2025-10-16T17:56:38Z",
    #   "location_id" => 1035466617946,
    #   "min_volume" => 1,
    #   "order_id" => 7163873707,
    #   "price" => 1001.0,
    #   "range" => "solarsystem",
    #   "system_id" => 30000240,
    #   "type_id" => 5339,
    #   "volume_remain" => 44,
    #   "volume_total" => 50
    # },

    rows =
      Enum.map(orders, fn order ->
        [
          {:duration, order["duration"]},
          {:is_buy_order, order["is_buy_order"]},
          {:issued, order["issued"]},
          {:location_id, order["location_id"]},
          {:min_volume, order["min_volume"]},
          {:order_id, order["order_id"]},
          {:price, order["price"]},
          {:range, order["range"]},
          {:system_id, order["system_id"]},
          {:type_id, order["type_id"]},
          {:volume_remain, order["volume_remain"]},
          {:volume_total, order["volume_total"]}
        ]
      end)

      IO.inspect(rows)

    Marketmailer.Database.insert_all(Market, rows)
  end
end
