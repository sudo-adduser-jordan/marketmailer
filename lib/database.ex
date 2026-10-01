defmodule Database do
	# database connection
	use Ecto.Repo,
		otp_app: :marketmailer,
		adapter: Ecto.Adapters.SQLite3
end

defmodule Etag.Database do
	import Ecto.Query

	# Absurd-future cap: an expires_at further out than this is treated as an
	# unexpected entry (bad Expires header / clock skew) and refetched.
	@max_ttl_ms 1_800_000

	def get_etag(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, etag, _expires_at}] -> etag
			[{^url, etag}] -> etag
			_ -> fetch_etag(url)
		end
	end

	def get_expiry(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, _etag, expires_at}] when is_integer(expires_at) -> expires_at
			[{^url, _etag}] -> fetch_expiry(url)
			_ -> fetch_expiry(url)
		end
	end

	# Milliseconds until this URL may be refetched. Returns 0 (fetch now) for
	# every unexpected entry: missing row, NULL, non-integer, expired, absurdly
	# far future, or an unreachable database. Unexpected entries log once.
	def resume_delay_ms(url) do
		now = System.system_time(:millisecond)

		try do
			case get_expiry(url) do
				expires_at when is_integer(expires_at) and expires_at > now and expires_at <= now + @max_ttl_ms ->
					expires_at - now

				other ->
					reason =
						cond do
							is_nil(other) -> :missing
							not is_integer(other) -> :bad_type
							other <= now -> :expired
							true -> :absurd_future
						end

					unexpected(url, reason)
					0
			end
		rescue
			_ ->
				unexpected(url, :db_error)
				0
		end
	end

	defp unexpected(url, reason) do
		Marketmailer.Log.info(
			"etag_unexpected",
			%{url: url, reason: reason},
			"etag entry #{reason}, fetching now: #{url}"
		)
	end

	# Pages with a known etag row for a region, parsed from the stored URLs.
	# Unparseable URLs are unexpected entries: ignored for pre-start, logged.
	def pages_for_region(region) when is_integer(region) do
		prefix = "https://esi.evetech.net/v1/markets/#{region}/orders/"

		from(tag in "etags", where: like(tag.url, ^"#{prefix}%"), select: tag.url)
		|> Database.all()
		|> Enum.flat_map(fn url ->
			case page_from_url(url) do
				nil ->
					Marketmailer.Log.info(
						"etag_unexpected",
						%{url: url, reason: :unparseable_url},
						"ignoring unparseable etag url: #{url}"
					)

					[]

				page ->
					[page]
			end
		end)
		|> Enum.uniq()
	rescue
		_ -> []
	end

	def page_from_url(url) when is_binary(url) do
		case Regex.run(~r/[?&]page=(\d+)/, url, capture: :all_but_first) do
			[n] -> String.to_integer(n)
			_ -> nil
		end
	end

	def max_ttl_ms, do: @max_ttl_ms

	defp fetch_etag(url) do
		query = from(tag in "etags", where: tag.url == ^url, select: {tag.etag, tag.expires_at})

		case Database.one(query) do
			nil ->
				nil

			{etag, expires_at} ->
				:ets.insert(:market_cache, {url, etag, expires_at})
				etag
		end
	end

	defp fetch_expiry(url) do
		query = from(tag in "etags", where: tag.url == ^url, select: tag.expires_at)

		case Database.one(query) do
			nil -> nil
			expires_at -> expires_at
		end
	end

	def upsert_etag(url, etag, expires_at \\ nil) do
		now = NaiveDateTime.utc_now(:second)

		Database.insert_all(
			"etags",
			[%{url: url, etag: etag, expires_at: expires_at, inserted_at: now, updated_at: now}],
			on_conflict: {:replace, [:etag, :expires_at, :updated_at]},
			conflict_target: :url
		)

		:ets.insert(:market_cache, {url, etag, expires_at})
	end
end

defmodule Discord.Database do
	import Ecto.Query

	@table "discord"

	def get(guild_id), do: Database.get(Discord, guild_id)

	def registered_channels do
		Database.all(from channel in Discord, select: channel.channel_id, order_by: [asc: channel.guild_id])
	end

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
	import Ecto.Query

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

	def get_market_item(item_name) when is_binary(item_name) do
		item_name = String.trim(item_name)

		if item_name != "" do
			case load_rows("getMarketItem.sql", [item_name]) do
				[] ->
					backfill_market_type_names()

					case load_rows("getMarketItem.sql", [item_name]) do
						[] -> nil
						[item | _] -> item
					end

				[item | _] ->
					backfill([item])
					load_rows("getMarketItem.sql", [item_name]) |> List.first()
			end
		end
	end

	def get_market_item(_item_name), do: nil

	def get_items_less_than_jita_buy do
		backfill(load_rows("getItemsLessThan.sql"))
		load_rows("getItemsLessThan.sql")
	end

	def get_list_less_than_jita_buy, do: []

	# Runs a query file from lib/ and returns one map/struct per row.
	defp load_rows(file, params \\ []) do
		{:ok, %{rows: rows, columns: cols}} = Database.query(read_sql(file), params)

		Enum.map(rows, fn row ->
			data = cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()

			if file in ["getBestOrder.sql", "getMarketItem.sql"] do
				struct = Ecto.Repo.Schema.load(Ecto.Adapters.SQLite3, MarketView, data)
				Map.put(struct, :instant_sell_profit, data[:instant_sell_profit])
			else
				data
			end
		end)
	end

	defp read_sql(file), do: File.read!(Path.join(__DIR__, file))

	# A name lookup cannot discover an unresolved type id from the market query
	# itself, so fill the type-name cache before retrying an item lookup.
	defp backfill_market_type_names do
		query =
			from market in @table,
				left_join: name in "names",
				on: name.id == market.type_id,
				where: is_nil(name.id),
				select: market.type_id,
				distinct: true

		case Database.all(query) do
			[] -> :ok
			ids -> ids |> ESI.Names.resolve() |> Universe.Database.upsert_names()
		end
	end

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
		type_id =
			if is_nil(Map.get(row, :item_name)) and is_nil(Map.get(row, :item)),
				do: Map.get(row, :type_id)

		location_id = if is_nil(Map.get(row, :location_name)), do: Map.get(row, :location_id)

		[type_id, location_id] |> Enum.reject(&is_nil/1)
	end
end
