
defmodule Marketmailer.Client do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    IO.puts("init")
    schedule_fetch()
    {:ok, state}
  end

  def handle_info(:fetch, state) do
      IO.puts("handle_info \t| #{inspect(System.monotonic_time())}")
    schedule_fetch()
    {:noreply, state}
  end

  defp schedule_fetch do
    IO.puts("schedule_fetch")
    Process.send_after(self(), :fetch, 600)
  end
end
