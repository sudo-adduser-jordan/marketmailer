defmodule Database do
	use Ecto.Repo,
		otp_app: :marketmailer,
		adapter: Ecto.Adapters.SQLite3
end

defmodule Database.Queue do
	use GenServer

	def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	def write(fun) when is_function(fun, 0) do
		case Process.whereis(__MODULE__) do
			nil -> fun.()
			_ -> GenServer.call(__MODULE__, {:write, fun}, :infinity)
		end
	end

	@impl true
	def init(_), do: {:ok, %{}}

	@impl true
	def handle_call({:write, fun}, _from, state) do
		{:reply, fun.(), state}
	end
end

defmodule Database.Writer do
	def write(fun) when is_function(fun, 0) do
		Database.Queue.write(fun)
	rescue
		e ->
			if disk_full?(e) do
				Marketmailer.Log.error(
					"disk_full",
					%{reason: Exception.message(e)},
					"Database or disk is full; skipping write"
				)
			end

			raise e
	end

	def disk_full?(%Exqlite.Error{} = e), do: String.contains?(Exception.message(e), "database or disk is full")

	def disk_full?(%DBConnection.ConnectionError{} = e),
		do: String.contains?(Exception.message(e), "database or disk is full")

	def disk_full?(e) when is_binary(e), do: String.contains?(e, "database or disk is full")
	def disk_full?(e) when is_atom(e), do: e == :disk_full

	def disk_full?(e) do
		e |> Exception.message() |> String.contains?("database or disk is full")
	rescue
		_ -> false
	catch
		_, _ -> false
	end
end

defmodule Etag.Database do
	import Ecto.Query

	@max_ttl_ms 1_800_000

	def get_etag(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, etag, _expires_at}] -> etag
			_ -> fetch_etag(url)
		end
	end

	def get_expiry(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, _etag, expires_at}] when is_integer(expires_at) -> expires_at
			_ -> fetch_expiry(url)
		end
	end

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

	def prune_region(region, max_page) when is_integer(region) and is_integer(max_page) do
		prefix = "https://esi.evetech.net/v1/markets/#{region}/orders/"

		dead =
			from(tag in "etags", where: like(tag.url, ^"#{prefix}%"), select: tag.url)
			|> Database.all()
			|> Enum.filter(fn url -> (page_from_url(url) || 0) > max_page end)
			|> Enum.uniq()

		if dead != [] do
			if :ets.whereis(:market_cache) != :undefined do
				Enum.each(dead, &:ets.delete(:market_cache, &1))
			end

			Database.Writer.write(fn ->
				Database.delete_all(from(tag in "etags", where: tag.url in ^dead))
			end)
		end

		:ok
	rescue
		_ -> :ok
	end

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

		Database.Writer.write(fn ->
			Database.insert_all(
				"etags",
				[%{url: url, etag: etag, expires_at: expires_at, inserted_at: now, updated_at: now}],
				on_conflict: {:replace, [:etag, :expires_at, :updated_at]},
				conflict_target: :url
			)
		end)

		:ets.insert(:market_cache, {url, etag, expires_at})
	end

	def touch_cache(url, etag, expires_at) do
		:ets.insert(:market_cache, {url, etag, expires_at})
		:ok
	end
end

defmodule Discord.Database do
	import Ecto.Query

	@table "discord"

	def get(guild_id), do: Database.get(Discord, guild_id)

	def registered_channels do
		Database.all(from channel in Discord, select: channel.channel_id, order_by: [asc: channel.guild_id])
	end

	def delete_by_channel(channel_id) do
		Database.Writer.write(fn ->
			Database.delete_all(from channel in Discord, where: channel.channel_id == ^channel_id)
		end)
	end

	def upsert(guild_id, channel_id) do
		now = NaiveDateTime.utc_now(:second)

		Database.Writer.write(fn ->
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
		end)
	end

	def delete(guild_id) do
		case get(guild_id) do
			nil -> :ok
			record -> Database.Writer.write(fn -> Database.delete(record) end)
		end
	end
end

defmodule Market.Database do
	import Ecto.Query

	@fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total)a
	@compare_fields ~w(duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total)a
	@table "market"

	@upsert_chunk_size 1000

	def upsert_orders(orders, url \\ nil) do
		timestamp = NaiveDateTime.utc_now(:second)

		rows =
			Enum.map(orders, fn order ->
				@fields
				|> Map.new(fn field -> {field, order[Atom.to_string(field)]} end)
				|> Map.update!(:is_buy_order, fn
					true -> 1
					false -> 0
					other -> other
				end)
				|> Map.merge(%{url: url, inserted_at: timestamp, updated_at: timestamp})
			end)

		Database.Writer.write(fn ->
			{changed, seen_ids} =
				if is_binary(url) do
					existing =
						from(m in "market",
							where: m.url == ^url,
							select:
								{m.order_id, m.duration, m.is_buy_order, m.issued, m.location_id, m.min_volume, m.price, m.range,
								 m.system_id, m.type_id, m.volume_remain, m.volume_total}
						)
						|> Database.all()
						|> Map.new(fn {order_id, duration, is_buy, issued, location_id, min_volume, price, range, system_id,
													 type_id, volume_remain, volume_total} ->
							{order_id,
							 %{
								 duration: duration,
								 is_buy_order: is_buy,
								 issued: issued,
								 location_id: location_id,
								 min_volume: min_volume,
								 price: price,
								 range: range,
								 system_id: system_id,
								 type_id: type_id,
								 volume_remain: volume_remain,
								 volume_total: volume_total
							 }}
						end)

					changed =
						Enum.filter(rows, fn row ->
							case Map.get(existing, row.order_id) do
								nil ->
									true

								prev ->
									Enum.any?(@compare_fields, fn field ->
										normalize_field(field, Map.get(prev, field)) != Map.get(row, field)
									end)
							end
						end)

					{changed, MapSet.new(rows, & &1.order_id)}
				else
					{rows, MapSet.new(rows, & &1.order_id)}
				end

			written =
				changed
				|> Enum.chunk_every(@upsert_chunk_size)
				|> Enum.reduce(0, fn chunk, total ->
					{count, _} =
						Database.insert_all(@table, chunk,
							on_conflict: {:replace, @fields ++ [:url, :updated_at]},
							conflict_target: :order_id
						)

					total + count
				end)

			if is_binary(url) do
				stale_ids =
					from(m in "market", where: m.url == ^url, select: m.order_id)
					|> Database.all()
					|> Enum.reject(&MapSet.member?(seen_ids, &1))

				Enum.chunk_every(stale_ids, @upsert_chunk_size)
				|> Enum.each(fn chunk ->
					Database.delete_all(from m in "market", where: m.order_id in ^chunk)
				end)
			end

			written
		end)
	end

	def upsert_chunk_size, do: @upsert_chunk_size

	defp normalize_field(:is_buy_order, true), do: 1
	defp normalize_field(:is_buy_order, false), do: 0
	defp normalize_field(_field, value), do: value

	def get_best_order do
		load_rows("getBestOrder.sql")
	rescue
		e ->
			Marketmailer.Log.warning(
				"query_failed",
				%{file: "getBestOrder.sql", reason: Exception.message(e)},
				"Market query failed for getBestOrder.sql"
			)

			[]
	end

	def get_market_item(item_name) when is_binary(item_name) do
		normalized = normalize_item_name(item_name)

		if normalized != "" do
			try do
				params = [normalized, "%#{escape_like(normalized)}%", normalized]

				load_rows("getMarketItem.sql", params) |> List.first()
			rescue
				e ->
					Marketmailer.Log.warning(
						"query_failed",
						%{file: "getMarketItem.sql", reason: Exception.message(e)},
						"Market query failed for getMarketItem.sql"
					)

					nil
			end
		end
	end

	def get_market_item(_item_name), do: nil

	def suggest_items(prefix, limit \\ 25)

	def suggest_items(prefix, limit) when is_binary(prefix) and is_integer(limit) do
		normalized = normalize_item_name(prefix)

		if normalized == "" do
			[]
		else
			escaped = escape_like(normalized)
			load_rows("suggestItems.sql", ["%#{escaped}%", "#{escaped}%", limit])
		end
	rescue
		_ -> []
	catch
		_, _ -> []
	end

	def suggest_items(_prefix, _limit), do: []

	def get_items_less_than_jita_buy do
		load_rows("getItemsLessThan.sql")
	rescue
		e ->
			Marketmailer.Log.warning(
				"query_failed",
				%{file: "getItemsLessThan.sql", reason: Exception.message(e)},
				"Market query failed for getItemsLessThan.sql"
			)

			[]
	end

	defp load_rows(file, params \\ []) do
		case Database.query(read_sql(file), params) do
			{:ok, %{rows: rows, columns: cols}} ->
				Enum.map(rows, fn row ->
					data = cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()

					if file in ["getBestOrder.sql", "getMarketItem.sql"] do
						struct = Ecto.Repo.Schema.load(Ecto.Adapters.SQLite3, MarketView, data)

						struct
						|> Map.put(:instant_sell_profit, data[:instant_sell_profit])
						|> Map.put(:buy_price, data[:buy_price])
					else
						data
					end
				end)

			{:error, reason} ->
				Marketmailer.Log.warning(
					"market_query_failed",
					%{file: file, reason: inspect(reason)},
					"Market query #{file} failed: #{inspect(reason)}"
				)

				[]
		end
	rescue
		e ->
			Marketmailer.Log.warning(
				"market_query_failed",
				%{file: file, reason: Exception.message(e)},
				"Market query #{file} failed: #{Exception.message(e)}"
			)

			[]
	end

	defp read_sql(file), do: File.read!(Path.join(__DIR__, file))

	def normalize_item_name(name) do
		name |> String.trim() |> String.replace(~r/\s+/, " ") |> String.trim() |> String.downcase()
	end

	defp escape_like(value) do
		value |> String.replace("\\", "\\\\") |> String.replace("%", "\\%") |> String.replace("_", "\\_")
	end
end
