defmodule Marketmailer.RegionManager do
  use GenServer

  def start_link(region_id),
    do: GenServer.start_link(__MODULE__, region_id, name: via(region_id))

  defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

  def init(id) do
    # Start ONLY page 1 immediately
    DynamicSupervisor.start_child(Marketmailer.PageSup, {Marketmailer.PageWorker, {id, 1}})
    # We know at least page 1 exists
    {:ok, %{id: id, page_count: 1}}
  end

  def handle_info({:update_page_count, new_count}, %{id: id, page_count: current} = state) do
    if new_count != current do
      adjust_workers(id, current, new_count)
      {:noreply, %{state | page_count: new_count}}
    else
      {:noreply, state}
    end
  end

  defp adjust_workers(id, old, new) when new > old do
    Enum.each((old + 1)..new, fn p ->
      DynamicSupervisor.start_child(Marketmailer.PageSup, {Marketmailer.PageWorker, {id, p}})
    end)
  end

  defp adjust_workers(id, old, new) when new < old do
    Enum.each((new + 1)..old, fn p ->
      # Gracefully stop workers that are no longer needed
      case Registry.lookup(Marketmailer.Registry, {:page, id, p}) do
        [{pid, _}] -> GenServer.stop(pid)
        _ -> :ok
      end
    end)
  end
end
