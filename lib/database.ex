# database connection
defmodule Marketmailer.Repo do
	use Ecto.Repo,
		otp_app: :marketmailer,
		adapter: Ecto.Adapters.Postgres
end

defmodule Etag.Database do
	import Ecto.Query

	alias Marketmailer.Repo

	def get_etag(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, etag}] -> etag
			_ -> fetch_etag(url)
		end
	end

	defp fetch_etag(url) do
		query = from(tag in "etags", where: tag.url == ^url, select: tag.etag)

		case Repo.one(query) do
			nil ->
				nil

			etag ->
				:ets.insert(:market_cache, {url, etag})
				etag
		end
	end

	def upsert_etag(url, etag) do
		now = NaiveDateTime.utc_now(:second)

		Repo.insert_all(
			"etags",
			[%{url: url, etag: etag, inserted_at: now, updated_at: now}],
			on_conflict: {:replace, [:etag, :updated_at]},
			conflict_target: :url
		)

		:ets.insert(:market_cache, {url, etag})
	end
end

defmodule Discord.Database do
	import Ecto.Query

	alias Marketmailer.Repo

	@table "discord_channels"

	def get(guild_id), do: Repo.get_by(@table, guild_id: guild_id)

	def all, do: Repo.all(from(d in @table, select: d))

	def upsert(guild_id, channel_id) do
		now = NaiveDateTime.utc_now(:second)

		Repo.insert_all(
			@table,
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

	def delete(guild_id) do
		case get(guild_id) do
			nil -> :ok
			record -> Repo.delete(record)
		end
	end
end

defmodule Marketmailer.Database do
	import Ecto.Query

	alias Marketmailer.Repo

	@fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total)a
	@table "markets"

	def upsert_orders(orders) do
		timestamp = NaiveDateTime.utc_now(:second)

		rows =
			Enum.map(orders, fn order ->
				@fields
				|> Map.new(fn field -> {field, order[Atom.to_string(field)]} end)
				|> Map.merge(%{inserted_at: timestamp, updated_at: timestamp})
			end)

		# We include :updated_at in the replace list so we know when data last changed
		Repo.insert_all(@table, rows,
			on_conflict: {:replace, @fields ++ [:updated_at]},
			conflict_target: :order_id
		)
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

		Repo.all(query)
	end

	def cheapest_order do
		query = from(m in @table, order_by: [asc: m.price], limit: 1)
		Repo.one(query)
	end

	def load_postgres_dmp, do: :ok
	def create_market_view, do: :ok
	def get_list_less_than_jita_buy, do: []
end
