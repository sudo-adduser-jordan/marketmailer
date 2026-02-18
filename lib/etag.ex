defmodule Marketmailer.EtagWarmup do
	use GenServer

	import Ecto.Query

	def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_) do
		send(self(), :warmup)
		{:ok, %{}}
	end

	@impl true
	def handle_info(:warmup, s) do
		for {url, e} <- Database.all(from e in Etag, select: {e.url, e.etag}),
				do: :ets.insert(:market_cache, {url, e})

		{:noreply, s}
	end
end
