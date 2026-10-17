defmodule Database do
	use Ecto.Repo,
		otp_app: :marketmailer,
		adapter: Ecto.Adapters.SQLite3
end

defmodule Database.Queue do
	use GenServer

	# SQLite has a single writer. Funneling every write through this one
	# process means write statements never contend on the database lock and
	# are never dropped by the connection pool: a caller blocks until its
	# write is persisted (or a real error is returned). Reads keep using the
	# full connection pool.
	def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	def write(fun) when is_function(fun, 0) do
		case Process.whereis(__MODULE__) do
			nil -> Database.Writer.run(fun)
			_ -> GenServer.call(__MODULE__, {:write, fun}, :infinity)
		end
	end

	@impl true
	def init(_), do: {:ok, %{}}

	@impl true
	def handle_call({:write, fun}, _from, state) do
		{:reply, Database.Writer.run(fun), state}
	end

	# Absorb stray messages so a wayward send can never take the writer down.
	@impl true
	def handle_info(_message, state), do: {:noreply, state}
end

defmodule Database.Writer do
	# Bounded backoff. Serialization absorbs contention; this is the last
	# line of defence for a transient SQLite/DBConnection error.
	@retry_delays [10, 25, 50, 100, 200, 400, 800, 1_600, 3_200]

	def write(fun) when is_function(fun, 0), do: Database.Queue.write(fun)

	# Runs a write closure, retrying transient contention, and returns
	# {:ok, result} or {:error, exception}. Never raises, never drops
	# silently: an exhausted retry surfaces the error to the caller.
	def run(fun) when is_function(fun, 0), do: attempt(fun, @retry_delays)

	defp attempt(fun, delays) do
		{:ok, fun.()}
	rescue
		e ->
			cond do
				disk_full?(e) ->
					Marketmailer.Log.error(
						"disk_full",
						%{reason: Exception.message(e)},
						"Database or disk is full; write failed"
					)

					{:error, e}

				retryable?(e) and delays != [] ->
					[wait | rest] = delays
					Process.sleep(wait + :rand.uniform(10))
					attempt(fun, rest)

				true ->
					{:error, e}
			end
	end

	def retryable?(%DBConnection.ConnectionError{}), do: true
	def retryable?(%Exqlite.Error{} = e), do: String.starts_with?(Exception.message(e), "Database busy")
	def retryable?(_), do: false

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
			_ -> fetch(url) |> elem(0)
		end
	end

	def get_expiry(url) do
		case :ets.lookup(:market_cache, url) do
			[{^url, _etag, expires_at}] when is_integer(expires_at) -> expires_at
			_ -> fetch(url) |> elem(1)
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

			case Database.Writer.write(fn ->
						 Database.delete_all(from(tag in "etags", where: tag.url in ^dead))
					 end) do
				{:ok, _} ->
					:ok

				{:error, e} ->
					Marketmailer.Log.warning(
						"etag_prune_failed",
						%{region: region, reason: Exception.message(e)},
						"Failed to prune etags above page #{max_page} for region #{region}"
					)
			end
		end

		:ok
	rescue
		_ -> :ok
	end

	# One query for both readers: the cache is authoritative when present,
	# otherwise the DB row is read and cached back.
	defp fetch(url) do
		query = from(tag in "etags", where: tag.url == ^url, select: {tag.etag, tag.expires_at})

		case Database.one(query) do
			nil ->
				{nil, nil}

			{etag, expires_at} = row ->
				:ets.insert(:market_cache, {url, etag, expires_at})
				row
		end
	end

	def upsert_etag(url, etag, expires_at \\ nil) do
		now = NaiveDateTime.utc_now(:second)

		case Database.Writer.write(fn ->
					 Database.insert_all(
						 "etags",
						 [%{url: url, etag: etag, expires_at: expires_at, inserted_at: now, updated_at: now}],
						 on_conflict: {:replace, [:etag, :expires_at, :updated_at]},
						 conflict_target: :url
					 )
				 end) do
			# Only cache the etag once the row is durable, so a failed write can
			# never mask a page the database has not seen.
			{:ok, _} ->
				:ets.insert(:market_cache, {url, etag, expires_at})
				:ok

			{:error, e} ->
				{:error, e}
		end
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

		raise_on_error(
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
		)
	end

	def delete(guild_id) do
		case get(guild_id) do
			nil -> :ok
			record -> raise_on_error(Database.Writer.write(fn -> Database.delete(record) end))
		end
	end

	# Slash-command handlers respond only after this returns, so a failed
	# write must raise (and be logged) rather than report false success.
	defp raise_on_error({:ok, _}), do: :ok
	defp raise_on_error({:error, e}), do: raise(e)
end

defmodule Market.Database do
	import Ecto.Query

	@fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total)a
	@compare_fields @fields -- [:order_id]
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

		case Database.Writer.write(fn -> write_page(rows, url) end) do
			{:ok, written} -> written
			{:error, e} -> {:error, e}
		end
	end

	# One transaction per page: the insert and the stale-id delete commit
	# together, so a partial failure can never leave a page half-updated (or
	# delete rows the insert did not replace).
	defp write_page(rows, url) do
		case Database.transaction(fn ->
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
								 |> Map.new(fn row ->
									 # The select list after order_id is exactly @compare_fields, in order.
									 [order_id | values] = Tuple.to_list(row)

									 {order_id, @compare_fields |> Enum.zip(values) |> Map.new()}
								 end)

							 changed =
								 Enum.filter(rows, fn row ->
									 case Map.get(existing, row.order_id) do
										 nil ->
											 true

										 prev ->
											 Enum.any?(@compare_fields, fn field ->
												 normalize_field(field, prev[field]) != row[field]
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
				 end) do
			{:ok, written} -> written
			{:error, reason} -> raise "market upsert transaction failed: #{inspect(reason)}"
		end
	end

	def upsert_chunk_size, do: @upsert_chunk_size

	defp normalize_field(:is_buy_order, true), do: 1
	defp normalize_field(:is_buy_order, false), do: 0
	defp normalize_field(_field, value), do: value

	def get_best_order, do: load_rows("getBestOrder.sql")

	def get_market_item(item_name) when is_binary(item_name) do
		case normalize_item_name(item_name) do
			"" ->
				nil

			normalized ->
				params = [normalized, "%#{escape_like(normalized)}%", normalized]

				load_rows("getMarketItem.sql", params) |> List.first()
		end
	end

	def get_market_item(_item_name), do: nil

	def suggest_items(prefix, limit \\ 25)

	def suggest_items(prefix, limit) when is_binary(prefix) and is_integer(limit) do
		case normalize_item_name(prefix) do
			"" ->
				[]

			normalized ->
				escaped = escape_like(normalized)

				load_rows("suggestItems.sql", ["%#{escaped}%", "#{escaped}%", limit])
		end
	end

	def suggest_items(_prefix, _limit), do: []

	def get_items_less_than_jita_buy, do: load_rows("getItemsLessThan.sql")

	defp load_rows(file, params \\ []) do
		structs? = file in ["getBestOrder.sql", "getMarketItem.sql"]

		case Database.query(read_sql(file), params) do
			{:ok, %{rows: rows, columns: cols}} ->
				keys = Enum.map(cols, &String.to_atom/1)

				Enum.map(rows, fn row ->
					data = keys |> Enum.zip(row) |> Map.new()

					if structs? do
						Ecto.Repo.Schema.load(Ecto.Adapters.SQLite3, MarketView, data)
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
