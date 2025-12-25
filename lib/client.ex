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
    data = Task.async_stream(regions, fn region ->
        IO.inspect(region)
        data_region = Esi.Api.Markets.orders(region, order_type: "all") |> Enum.to_list()
        IO.inspect("#{region} complete")
        data_region
    end, timeout: 300_000) |> Enum.to_list()

    IO.inspect(data)
  end
end
