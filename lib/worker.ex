defmodule Marketmailer.PageWorker do
  use GenServer, restart: :transient

  def start_link({region_id, page}),
    do: GenServer.start_link(__MODULE__, {region_id, page}, name: via(region_id, page))

  defp via(region_id, page),
    do: {:via, Registry, {Marketmailer.Registry, {:page, region_id, page}}}

  def init({region_id, page}) do
    send(self(), :work)
    {:ok, {region_id, page}}
  end

  def handle_info(:work, {region_id, page} = state) do
    case Marketmailer.ESI.fetch(region_id, page) do
      {:ok, data, meta} ->

        Marketmailer.Database.upsert_orders(data)
        :ets.insert(:market_cache, {meta.url, meta.etag})

        notify_manager(region_id, meta.pages)
        schedule_next(meta.ttl)

      {:not_modified, meta} ->
        notify_manager(region_id, meta.pages)
        schedule_next(meta.ttl)

      {:error, _} ->
        IO.puts("fetch error")
        schedule_next(60_000)
    end

    {:noreply, state}
  end

  defp schedule_next(ttl), do: Process.send_after(self(), :work, ttl)

  defp notify_manager(region_id, count) do
    case Registry.lookup(Marketmailer.Registry, {:region, region_id}) do
      [{pid, _}] -> send(pid, {:update_page_count, count})
      _ -> :ok
    end
  end
end
