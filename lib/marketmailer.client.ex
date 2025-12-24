
defmodule MyClient.Worker do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_fetch()
    {:ok, state}
  end

  def handle_info(:fetch, state) do
    # Fetch logic here
    IO.puts("Fetching data...")
    schedule_fetch()
    {:noreply, state}
  end

  defp schedule_fetch do
    Process.send_after(self(), :fetch, 600)
  end
end
