defmodule Database do
	# database connection
	use Ecto.Repo,
		otp_app: :marketmailer,
		adapter: Ecto.Adapters.Postgres
end

defmodule Etag.Database do
	import Ecto.Query

	def get_etag(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, etag}] -> etag
			_ -> fetch_etag(url)
		end
	end

	defp fetch_etag(url) do
		query = from(tag in "etags", where: tag.url == ^url, select: tag.etag)

		case Database.one(query) do
			nil ->
				nil

			etag ->
				:ets.insert(:market_cache, {url, etag})
				etag
		end
	end

	def upsert_etag(url, etag) do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all(
			"etags",
			[%{url: url, etag: etag, inserted_at: now, updated_at: now}],
			on_conflict: {:replace, [:etag, :updated_at]},
			conflict_target: :url
		)

		:ets.insert(:market_cache, {url, etag})
	end
end

defmodule Discord.Database do
	@table "discord"

	def get(guild_id), do: Database.get(Discord, guild_id)

	def upsert(guild_id, channel_id) do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all(
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
			record -> Database.delete(record)
		end
	end
end

defmodule Market.Database do
	@fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total)a
	@table "market"

	def upsert_orders(orders) do
		timestamp = NaiveDateTime.utc_now(:second)

		rows =
			Enum.map(orders, fn order ->
				@fields
				|> Map.new(fn field -> {field, order[Atom.to_string(field)]} end)
				|> Map.merge(%{inserted_at: timestamp, updated_at: timestamp})
			end)

		Database.insert_all(@table, rows,
			on_conflict: {:replace, @fields ++ [:updated_at]},
			conflict_target: :order_id
		)
	end

	# It's better to use a path relative to the app root or priv for production safety
	# sql_path = Path.join([:code.priv_dir(:marketmailer), "queries", "getItemsLessThan.sql"])
	# sql_path = "/home/user1/Documents/GitHub/marketmailer/lib/getItemsLessThan.sql"
	def get_items_less_than_jita_buy do
		{:ok, %{rows: rows, columns: cols}} = Database.query(File.read!("./lib/getItemsLessThan.sql"))

		column_atoms = Enum.map(cols, &String.to_atom/1)

		Enum.map(rows, fn row ->
			Ecto.Repo.Schema.load(
				Ecto.Adapters.Postgres,
				MarketView,
				Enum.zip(column_atoms, row) |> Map.new()
			)
		end)
	end

	def get_best_order do
		{:ok, %{rows: rows, columns: cols}} = Database.query(File.read!("./lib/getBestOrder.sql"))

		column_atoms = Enum.map(cols, &String.to_atom/1)

		Enum.map(rows, fn row ->
			Ecto.Repo.Schema.load(
				Ecto.Adapters.Postgres,
				MarketView,
				Enum.zip(column_atoms, row) |> Map.new()
			)
		end)
	end

	def get_list_less_than_jita_buy, do: []
end
