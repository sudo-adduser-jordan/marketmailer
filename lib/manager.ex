defmodule Marketmailer.RegionManager do
	@moduledoc false
	use GenServer, restart: :permanent

	require Logger

	def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))
	defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

	@impl true
	def init(id) do
		start_page(id, 1)
		{:ok, %{id: id, page_count: 1}}
	end

	@impl true
	def handle_info({:update_page_count, count}, %{id: id, page_count: old} = state) do
		count = max(count, 1)

		if count == old do
			{:noreply, state}
		else
			Logger.debug("Region #{id}: pages #{old} -> #{count}")
			adjust_workers(id, old, count)
			{:noreply, %{state | page_count: count}}
		end
	end

	defp adjust_workers(id, old, new) do
		cond do
			new > old -> Enum.each((old + 1)..new, &start_page(id, &1))
			new < old -> Enum.each((new + 1)..old, &stop_page(id, &1))
			true -> :ok
		end
	end

	defp start_page(id, p) do
		case Registry.lookup(Marketmailer.Registry, {:page, id, p}) do
			[] ->
				DynamicSupervisor.start_child(
					Marketmailer.PageSup,
					{Marketmailer.PageWorker, {self(), id, p}}
				)

			_ ->
				:ok
		end
	end

	defp stop_page(id, p) do
		for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, id, p}),
				do: GenServer.stop(pid, :normal)
	end
end
