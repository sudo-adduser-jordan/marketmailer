defmodule Database do
	# database connection
	use Ecto.Repo,
		otp_app: :marketmailer,
		adapter: Ecto.Adapters.SQLite3
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
				# insert_all with a bare table name skips ecto type casting; sqlite
				# would store true/false as text and break `is_buy_order = 1` filters
				|> Map.update!(:is_buy_order, fn
					true -> 1
					false -> 0
					other -> other
				end)
				|> Map.merge(%{inserted_at: timestamp, updated_at: timestamp})
			end)

		Database.insert_all(@table, rows,
			on_conflict: {:replace, @fields ++ [:updated_at]},
			conflict_target: :order_id
		)
	end

	def get_best_order do
		backfill(load_rows("getBestOrder.sql"))
		load_rows("getBestOrder.sql")
	end

	def get_items_less_than_jita_buy do
		backfill(load_rows("getItemsLessThan.sql"))
		load_rows("getItemsLessThan.sql")
	end

	def get_list_less_than_jita_buy, do: []

	# Runs a query file from lib/ and returns one map/struct per row.
	defp load_rows(file) do
		{:ok, %{rows: rows, columns: cols}} = Database.query(read_sql(file))

		Enum.map(rows, fn row ->
			data = cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()

			if file == "getBestOrder.sql" do
				struct = Ecto.Repo.Schema.load(Ecto.Adapters.SQLite3, MarketView, data)
				Map.put(struct, :instant_sell_profit, data[:instant_sell_profit])
			else
				data
			end
		end)
	end

	defp read_sql(file), do: File.read!(Path.join(__DIR__, file))

	# Fills the lazy EVE caches (names/systems) for anything the query could not
	# resolve locally; the caller re-runs the query afterwards.
	defp backfill([]), do: []

	defp backfill(rows) do
		name_ids = rows |> Enum.flat_map(&name_gaps/1) |> Enum.uniq()

		system_ids =
			for row <- rows,
					Map.get(row, :system_id) != nil and
						(Map.get(row, :system_name) == nil or Map.get(row, :region_name) == nil),
					do: Map.get(row, :system_id)

		if name_ids != [], do: name_ids |> ESI.Names.resolve() |> Universe.Database.upsert_names()

		Enum.each(Enum.uniq(system_ids), fn system_id ->
			with {:ok, info} <- ESI.SystemInfo.fetch(system_id) do
				Universe.Database.upsert_system(info)
			end
		end)
	end

	defp name_gaps(row) do
		for {name_key, id_key} <- [item_name: :type_id, location_name: :location_id],
				Map.get(row, name_key) == nil and Map.get(row, id_key) != nil,
				do: Map.get(row, id_key)
	end
end
