defmodule EtagCache do
	use GenServer

	import Ecto.Query

	def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_) do
		send(self(), :warmup)
		{:ok, %{}}
	end

	@impl true
	def handle_info(:warmup, state) do
		for {url, etag, expires_at} <- Database.all(from tag in Etag, select: {tag.url, tag.etag, tag.expires_at}),
				do: :ets.insert(:market_cache, {url, etag, expires_at})

		{:noreply, state}
	end
end
