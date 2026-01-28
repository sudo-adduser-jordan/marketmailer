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
    regions = Req.get!("https://esi.evetech.net/v1/universe/regions").body |> IO.inspect()
    Marketmailer.Database.delete_all(Market )

    Task.async_stream(
      regions,
      fn region ->
        IO.inspect(region)


        orders = Esi.Api.Markets.orders(region, order_type: "all") |> Enum.to_list()

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

        Enum.chunk_every(rows, 2048)
        |> Enum.each(fn chunk ->
          Marketmailer.Database.insert_all(Market, chunk)
        end)

        IO.puts("#{region} complete")
      end,
      timeout: 300_000
    )
    |> Enum.to_list()
  end
end
