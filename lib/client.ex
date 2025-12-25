defmodule Marketmailer.Client do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_work()
    {:ok, state}
  end

  def handle_info(:work, state) do
    # Marketmailer.Requests.get_all_orders()
    schedule_work()
    {:noreply, state}
  end

  defp schedule_work do
    Process.send_after(self(), :work, 300_000)
  end

  defp get_pages(region) do
    response =
      "https://esi.evetech.net/v1/markets/#{region}/orders/"
      |> IO.inspect()
      |> Req.get!()

    pages =
      response.headers["x-pages"]
      |> List.first()
      |> String.to_integer()

    for page <- 1..pages do
      "https://esi.evetech.net/v1/markets/#{region}/orders?page=#{page}"
    end
  end

  def get_regions do
    Req.get!("https://esi.evetech.net/v1/universe/regions").body
  end

  def get_orders_region(region) do
    delay = fn n -> trunc(Integer.pow(2, n) * 1000 * (1 - 0.1 * :rand.uniform())) end

    get_pages(region)
    |> Task.async_stream(
      fn url ->
        url
        |> IO.inspect()
        |> Req.get!(retry_delay: delay)
        |> Map.get(:body)
      end,
      timeout: 69_000
    )
    |> Enum.flat_map(fn {:ok, result} -> result end)
  end

  def get_orders do
    get_regions()
    |> Task.async_stream(
      fn region ->
        get_orders_region(region)
      end,
      max_concurrency: 69,
      timeout: 420_000
    )
    |> Enum.flat_map(fn {:ok, result} -> result end)
  end
end
