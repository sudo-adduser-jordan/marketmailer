defmodule Etag do
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
		for {url, etag} <- Database.all(from tag in Etag, select: {tag.url, tag.etag}),
				do: :ets.insert(:market_cache, {url, etag})

		{:noreply, state}
	end
end

defmodule Etag do
	use Ecto.Schema

	import Ecto.Changeset

	schema "etags" do
		field :etag, :string
		field :url, :string
		timestamps()
	end

	def changeset(etag, attrs),
		do: etag |> cast(attrs, [:url, :etag]) |> validate_required([:url, :etag]) |> unique_constraint(:url)
end
