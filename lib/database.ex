defmodule Marketmailer.Database do
	@moduledoc false
	use Ecto.Repo, otp_app: :marketmailer, adapter: Ecto.Adapters.Postgres

	import Ecto.Query

	@fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total inserted_at updated_at)a

	def upsert_orders(orders) do
		ts = NaiveDateTime.utc_now(:second)

		rows =
			Enum.map(orders, fn o ->
				@fields
				|> Map.new(fn f -> {f, o[Atom.to_string(f)]} end)
				|> Map.merge(%{inserted_at: ts, updated_at: ts})
			end)

		insert_all(Market, rows, on_conflict: {:replace, @fields}, conflict_target: :order_id)
	end

	def get_etag(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, etag}] -> etag
			_ -> fetch_etag(url)
		end
	end

	defp fetch_etag(url) do
		case one(from e in Etag, where: e.url == ^url, select: e.etag) do
			nil ->
				nil

			etag ->
				:ets.insert(:market_cache, {url, etag})
				etag
		end
	end

	def upsert_etag(url, etag) do
		now = NaiveDateTime.utc_now(:second)

		insert_all(Etag, [%{url: url, etag: etag, inserted_at: now, updated_at: now}],
			on_conflict: {:replace, [:etag, :updated_at]},
			conflict_target: :url
		)

		:ets.insert(:market_cache, {url, etag})
	end

	def load_postgres_dmp do
	end

	def create_market_view do
	end

	def get_items_less_than_jita_buy do
		# import Ecto.Query
		# # Querying without a Schema module
		# query = from s in "solar_systems",
		#         select: %{id: s.solar_system_id, name: s.solar_system_name, sec: s.security}
		# Repo.all(query)

		# SELECT s.*, (b."price" - s."price") AS margin
		# FROM public."marketView" s
		# JOIN public."marketView" b
		#   ON s."item_name" = b."item_name"
		#   AND s."system_name" != 'Jita'
		#   AND b."system_name" = 'Jita'
		#   AND s."order_type" = 'SELL'
		#   AND b."order_type" = 'BUY'
		# WHERE s."price" < b."price"
		# ORDER BY margin DESC;
	end

	def get_list_less_than_jita_buy do
	end

	def cheapest_order do
		Market
		|> order_by(asc: :price)
		|> limit(1)
		|> one()
	end
end

defmodule Market do
	use Ecto.Schema

	@primary_key false
	schema "market" do
		field :order_id, :id, primary_key: true
		field :duration, :integer
		field :is_buy_order, :boolean
		field :issued, :string
		field :location_id, :integer
		field :min_volume, :integer
		field :price, :float
		field :range, :string
		field :system_id, :integer
		field :type_id, :integer
		field :volume_remain, :integer
		field :volume_total, :integer
		timestamps()
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
		for {url, e} <- Marketmailer.Database.all(from e in Etag, select: {e.url, e.etag}),
				do: :ets.insert(:market_cache, {url, e})

		{:noreply, s}
	end
end
