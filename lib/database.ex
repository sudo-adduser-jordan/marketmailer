defmodule Etag.Database do
	use Ecto.Repo, otp_app: :marketmailer, adapter: Ecto.Adapters.Postgres

	import Ecto.Query

	def get_etag(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, etag}] -> etag
			_ -> fetch_etag(url)
		end
	end

	defp fetch_etag(url) do
		case one(from tag in Etag, where: tag.url == ^url, select: tag.etag) do
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
end

defmodule Discord.Database do
	use Ecto.Schema

	@primary_key {:guild_id, :integer, autogenerate: false}
	schema "registered_channels" do
		field :channel_id, :integer
		timestamps()
	end

	def get(guild_id), do: Market.Database.get(__MODULE__, guild_id)

	def all, do: Market.Database.all(__MODULE__)

	def upsert(guild_id, channel_id) do
		now = NaiveDateTime.utc_now(:second)

		Market.Database.insert_all(
			__MODULE__,
			[
				%{
					guild_id: guild_id,
					channel_id: channel_id,
					inserted_at: now,
					updated_at: now
				}
			],
			on_conflict: {:replace, [:channel_id, :updated_at]},
			conflict_target: :guild_id
		)
	end

	@doc "Deletes a guild registration if it exists."
	def delete(guild_id) do
		case get(guild_id) do
			nil -> :ok
			struct -> Market.Database.delete(struct)
		end
	end
end

defmodule Market.Database do
	use Ecto.Repo, otp_app: :marketmailer, adapter: Ecto.Adapters.Postgres

	import Ecto.Query

	@fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total inserted_at updated_at)a

	def upsert_orders(orders) do
		timestamp = NaiveDateTime.utc_now(:second)

		rows =
			Enum.map(orders, fn order ->
				@fields
				|> Map.new(fn val -> {val, order[Atom.to_string(val)]} end)
				|> Map.merge(%{inserted_at: timestamp, updated_at: timestamp})
			end)

		insert_all(Market, rows, on_conflict: {:replace, @fields}, conflict_target: :order_id)
	end

	def load_postgres_dmp do
	end

	def create_market_view do
	end

	def get_items_less_than_jita_buy do
		query =
			from table_one in fragment("public.\"marketView\""),
				join: table_two in fragment("public.\"marketView\""),
				on:
					table_one.item_name == table_two.item_name and
						table_one.system_name != "Jita" and
						table_two.system_name == "Jita" and
						table_one.order_type == "SELL" and
						table_two.order_type == "BUY",
				where: table_one.price < table_two.price,
				select: %{
					item: table_one.item_name,
					buy_price: table_two.price,
					sell_price: table_one.price,
					margin: fragment("? - ?", table_two.price, table_one.price)
				},
				order_by: [asc: fragment("? - ?", table_two.price, table_one.price)],
				limit: 100

		__MODULE__.all(query)
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
