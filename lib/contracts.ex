defmodule Contracts do
	@defaults [
		enabled: true,
		period_ms: 1_800_000,
		initial_delay_ms: 30_000,
		region_concurrency: 4,
		excluded_types: ["courier", "auction", "loan", "unknown"],
		min_margin: 100_000_000,
		item_concurrency: 8,
		item_retry_ms: 1_800_000,
		item_retry_max_ms: 14_400_000,
		region_timeout_ms: 600_000,
		round_deadline_ms: 1_500_000,
		pause_recheck_ms: 30_000,
		page_limit: 5_000,
		broadcast_limit: 100,
		broadcast_per_page: 5,
		prune_grace_ms: 86_400_000
	]

	def config(overrides \\ []) do
		configured = Application.get_env(:marketmailer, :contracts, [])
		configured = if is_list(configured), do: configured, else: []

		@defaults
		|> Keyword.merge(configured)
		|> Keyword.merge(overrides)
	end

	def enabled?, do: Keyword.fetch!(config(), :enabled)

	def page_url(region, page \\ 1), do: ESI.contracts_page_url(region, page)

	def items_url(contract_id), do: ESI.contract_items_url(contract_id)

	def now_ms, do: System.system_time(:millisecond)

	def runtime do
		last_round = :persistent_term.get({Contracts, :round_stats}, nil)

		%{
			contract_page_workers: contract_page_workers(),
			contract_active_round: :persistent_term.get({Contracts, :active_round}, nil),
			contract_top_round: :persistent_term.get({Contracts, :top_round}, nil),
			contract_last_desired: if(is_map(last_round), do: Map.get(last_round, :desired))
		}
	end

	defp contract_page_workers do
		if Process.whereis(Marketmailer.Registry) do
			Marketmailer.Registry
			|> Registry.select([{{{:contract_page, :"$1", :"$2"}, :_, :_}, [], [:"$2"]}])
			|> length()
		else
			0
		end
	rescue
		_ -> 0
	end

	def parse_iso(nil), do: nil

	def parse_iso(value) when is_binary(value) do
		case DateTime.from_iso8601(value) do
			{:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
			_ -> nil
		end
	end

	def parse_iso(_value), do: nil

	def excluded_type?(type, config) when is_binary(type) do
		type in Keyword.fetch!(config, :excluded_types)
	end

	def excluded_type?(_type, _config), do: true

	def candidate?(contract, config, now) when is_map(contract) do
		type = contract["type"]
		contract_id = contract["contract_id"]
		expires_at = parse_iso(contract["date_expired"])

		is_integer(contract_id) and
			is_binary(type) and
			not excluded_type?(type, config) and
			is_integer(expires_at) and
			expires_at > now
	end

	def candidate?(_contract, _config, _now), do: false

	def normalize(contract, region, page) do
		%{
			contract_id: contract["contract_id"],
			region_id: region,
			page: page,
			type: contract["type"],
			title: contract["title"] || "",
			price: number(contract["price"]),
			buyout: number(contract["buyout"]),
			reward: number(contract["reward"]),
			collateral: number(contract["collateral"]),
			volume: number(contract["volume"]),
			expires_at: parse_iso(contract["date_expired"]),
			issued_at: parse_iso(contract["date_issued"]),
			days_to_complete: contract["days_to_complete"],
			start_location_id: contract["start_location_id"],
			end_location_id: contract["end_location_id"],
			issuer_id: contract["issuer_id"],
			issuer_corporation_id: contract["issuer_corporation_id"]
		}
	end

	defp number(nil), do: nil
	defp number(value) when is_number(value), do: value
	defp number(_value), do: nil

	def error_reason(%{__struct__: module}) when is_atom(module), do: module |> Module.split() |> List.last()
	def error_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
	def error_reason(_reason), do: :unknown

	def error_detail(%{__exception__: true} = error), do: Exception.message(error)
	def error_detail(error), do: inspect(error)
end

defmodule Contracts.Database do
	import Ecto.Query

	@external_resource Path.join(__DIR__, "sql/contractTopDesired.sql")
	@external_resource Path.join(__DIR__, "sql/contractClaimItem.sql")
	@external_resource Path.join(__DIR__, "sql/contractReleaseItemClaim.sql")
	@external_resource Path.join(__DIR__, "sql/contractMarkItemFailed.sql")
	@external_resource Path.join(__DIR__, "sql/contractDeferItem.sql")
	@external_resource Path.join(__DIR__, "sql/contractMaxLastSeenRound.sql")

	@top_desired File.read!(Path.join(__DIR__, "sql/contractTopDesired.sql"))
	@claim_item File.read!(Path.join(__DIR__, "sql/contractClaimItem.sql"))
	@release_item_claim File.read!(Path.join(__DIR__, "sql/contractReleaseItemClaim.sql"))
	@mark_item_failed File.read!(Path.join(__DIR__, "sql/contractMarkItemFailed.sql"))
	@defer_item File.read!(Path.join(__DIR__, "sql/contractDeferItem.sql"))
	@max_last_seen_round File.read!(Path.join(__DIR__, "sql/contractMaxLastSeenRound.sql"))

	@chunk_size 500

	def upsert_page(contracts, region, page, round) do
		if contracts == [] do
			:ok
		else
			now = NaiveDateTime.utc_now(:second)

			rows =
				Enum.map(contracts, fn contract ->
					contract
					|> Map.put(:region_id, region)
					|> Map.put(:page, page)
					|> Map.put(:last_seen_round, round)
					|> Map.put(:inserted_at, now)
					|> Map.put(:updated_at, now)
				end)

			replace =
				[
					:region_id,
					:page,
					:type,
					:title,
					:price,
					:buyout,
					:reward,
					:collateral,
					:volume,
					:expires_at,
					:issued_at,
					:days_to_complete,
					:start_location_id,
					:end_location_id,
					:issuer_id,
					:issuer_corporation_id,
					:last_seen_round,
					:updated_at
				]

			case Database.Writer.write(fn ->
						 rows
						 |> Enum.chunk_every(@chunk_size)
						 |> Enum.each(fn chunk ->
							 Database.insert_all("contracts", chunk,
								 on_conflict: {:replace, replace},
								 conflict_target: :contract_id
							 )
						 end)
					 end) do
				{:ok, _} -> :ok
				{:error, error} -> {:error, error}
			end
		end
	end

	def mark_page_seen(region, page, round) do
		now = NaiveDateTime.utc_now(:second)
		now_ms = Contracts.now_ms()

		Database.Writer.write(fn ->
			Database.update_all(
				from(c in "contracts",
					where: c.region_id == ^region and c.page == ^page and c.expires_at > ^now_ms
				),
				set: [last_seen_round: round, updated_at: now]
			)
		end)
	end

	def claim_item(contract_id, round) do
		case Database.Writer.write(fn ->
					 %{num_rows: rows} =
						 Database.query!(@claim_item, [round, contract_id, round])

					 rows
				 end) do
			{:ok, rows} when rows > 0 -> true
			_ -> false
		end
	end

	def release_item_claim(contract_id) do
		Database.Writer.write(fn ->
			Database.query!(@release_item_claim, [contract_id])
		end)
	end

	def replace_items(contract_id, items) do
		now = NaiveDateTime.utc_now(:second)

		rows =
			items
			|> Enum.filter(&is_integer(&1["record_id"]))
			|> Enum.map(fn item ->
				%{
					record_id: item["record_id"],
					contract_id: contract_id,
					type_id: item["type_id"],
					quantity: item["quantity"],
					is_included: integer_boolean(item["is_included"], 1),
					is_blueprint_copy: integer_boolean(item["is_blueprint_copy"], 0)
				}
			end)

		Database.Writer.write(fn ->
			transaction!(fn ->
				Database.delete_all(from(i in "contract_items", where: i.contract_id == ^contract_id))

				rows
				|> Enum.chunk_every(@chunk_size)
				|> Enum.each(&Database.insert_all("contract_items", &1))

				Database.update_all(
					from(c in "contracts", where: c.contract_id == ^contract_id),
					set: [
						items_fetched: 1,
						items_attempts: 0,
						items_next_attempt_at: 0,
						items_claim_round: 0,
						updated_at: now
					]
				)
			end)
		end)
	end

	def mark_item_failed(contract_id, attempts, config) do
		next_attempt = Contracts.now_ms() + retry_delay(attempts, config)

		Database.Writer.write(fn ->
			Database.query!(@mark_item_failed, [next_attempt, contract_id])
		end)
	end

	def defer_item(contract_id, delay_ms) do
		next_attempt = Contracts.now_ms() + max(delay_ms, 0)

		Database.Writer.write(fn ->
			Database.query!(@defer_item, [next_attempt, contract_id])
		end)
	end

	def drop_contract(contract_id) do
		Database.Writer.write(fn ->
			transaction!(fn ->
				Database.delete_all(from(i in "contract_items", where: i.contract_id == ^contract_id))
				Database.delete_all(from(c in "contracts", where: c.contract_id == ^contract_id))
			end)
		end)
	end

	def item_candidates(region, page, round, config, now) do
		excluded = Keyword.fetch!(config, :excluded_types)
		limit = Keyword.fetch!(config, :page_limit)

		query =
			from(c in "contracts",
				where:
					c.region_id == ^region and c.page == ^page and
						c.items_fetched == 0 and c.last_seen_round == ^round and
						c.expires_at > ^now and c.items_next_attempt_at <= ^now and
						c.items_claim_round != ^round,
				order_by: [asc: c.price, desc: c.contract_id],
				limit: ^limit,
				select: %{contract_id: c.contract_id, items_attempts: c.items_attempts}
			)

		query =
			if excluded == [] do
				query
			else
				where(query, [c], c.type not in ^excluded)
			end

		Database.all(query)
	end

	def top_desired(round, limit, min_margin) do
		sql = @top_desired

		case Database.query(sql, [round, Contracts.now_ms(), min_margin, limit]) do
			{:ok, %{rows: rows, columns: columns}} ->
				keys = Enum.map(columns, &String.to_atom/1)
				Enum.map(rows, fn row -> keys |> Enum.zip(row) |> Map.new() end)

			{:error, error} ->
				Marketmailer.Log.warning(
					"contracts_query_failed",
					%{query: "top_desired", reason: Contracts.error_reason(error), detail: Contracts.error_detail(error)},
					"Contract top-100 query failed"
				)

				[]
		end
	end

	def item_names(contract_ids) do
		if contract_ids == [] do
			%{}
		else
			from(i in "contract_items",
				join: n in "names",
				on: n.id == i.type_id,
				where: i.contract_id in ^contract_ids and i.is_included == true and i.is_blueprint_copy == false,
				select: {i.contract_id, n.name, i.quantity},
				order_by: [desc: i.quantity]
			)
			|> Database.all()
			|> Enum.reduce(%{}, fn {contract_id, name, _quantity}, acc ->
				Map.update(acc, contract_id, [name], &[name | &1])
			end)
			|> Map.new(fn {contract_id, names} -> {contract_id, Enum.reverse(names)} end)
		end
	end

	def latest_round do
		case Database.query(@max_last_seen_round, []) do
			{:ok, %{rows: [[round]]}} -> round
			_ -> nil
		end
	end

	def prune(grace_ms) do
		cutoff = Contracts.now_ms() - grace_ms
		expired = from(c in "contracts", where: c.expires_at < ^cutoff, select: c.contract_id)

		Database.Writer.write(fn ->
			Database.transaction(fn ->
				Database.delete_all(from(i in "contract_items", where: i.contract_id in subquery(expired)))
				Database.delete_all(from(c in "contracts", where: c.expires_at < ^cutoff))
			end)
		end)
	end

	def pages_for_region(region) do
		prefix = "https://esi.evetech.net/v1/contracts/public/#{region}/?page="

		from(t in "etags", where: like(t.url, ^"#{prefix}%"), select: t.url)
		|> Database.all()
		|> Enum.flat_map(&List.wrap(Etag.Database.page_from_url(&1)))
		|> Enum.uniq()
	end

	def max_known_page(region) do
		pages_for_region(region) |> Enum.max(fn -> 1 end)
	end

	def prune_page_etags(region, max_page) do
		prefix = "https://esi.evetech.net/v1/contracts/public/#{region}/?page="

		dead =
			from(t in "etags", where: like(t.url, ^"#{prefix}%"), select: t.url)
			|> Database.all()
			|> Enum.filter(fn url -> (Etag.Database.page_from_url(url) || 0) > max_page end)

		if dead != [] do
			if :ets.whereis(:market_cache) != :undefined do
				Enum.each(dead, &:ets.delete(:market_cache, &1))
			end

			Database.Writer.write(fn ->
				Database.delete_all(from(t in "etags", where: t.url in ^dead))
			end)
		end

		:ok
	rescue
		_ -> :ok
	end

	defp transaction!(fun) when is_function(fun, 0) do
		case Database.transaction(fun) do
			{:ok, result} -> result
			{:error, reason} -> raise "database transaction failed: #{inspect(reason)}"
		end
	end

	defp retry_delay(attempts, config) do
		base = Keyword.fetch!(config, :item_retry_ms)
		max_delay = Keyword.fetch!(config, :item_retry_max_ms)

		(base * :math.pow(2, max(attempts, 0)))
		|> round()
		|> min(max_delay)
		|> max(base)
	end

	defp integer_boolean(nil, default), do: default
	defp integer_boolean(true, _default), do: 1
	defp integer_boolean(false, _default), do: 0
	defp integer_boolean(1, _default), do: 1
	defp integer_boolean(0, _default), do: 0
	defp integer_boolean(_value, default), do: default
end

defmodule Contracts.ItemGate do
	use GenServer

	def start_link(opts \\ []) do
		GenServer.start_link(__MODULE__, opts, name: __MODULE__)
	end

	def run(fun) when is_function(fun, 0) do
		case Process.whereis(__MODULE__) do
			nil ->
				fun.()

			_pid ->
				GenServer.call(__MODULE__, :acquire, :infinity)

				try do
					fun.()
				after
					GenServer.cast(__MODULE__, {:release, self()})
				end
		end
	end

	@impl true
	def init(_opts) do
		max = Contracts.config() |> Keyword.fetch!(:item_concurrency) |> max(1)
		{:ok, %{active: %{}, max: max, waiters: :queue.new()}}
	end

	@impl true
	def handle_call(:acquire, {pid, _tag} = from, state) do
		if map_size(state.active) < state.max do
			ref = Process.monitor(pid)
			{:reply, :ok, %{state | active: Map.put(state.active, pid, ref)}}
		else
			{:noreply, %{state | waiters: :queue.in({from, pid}, state.waiters)}}
		end
	end

	@impl true
	def handle_cast({:release, pid}, state) do
		case Map.pop(state.active, pid) do
			{nil, _active} ->
				{:noreply, state}

			{ref, active} ->
				Process.demonitor(ref, [:flush])
				{:noreply, promote(%{state | active: active})}
		end
	end

	@impl true
	def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
		case Map.get(state.active, pid) do
			^ref -> {:noreply, promote(%{state | active: Map.delete(state.active, pid)})}
			_ -> {:noreply, state}
		end
	end

	def handle_info(_message, state), do: {:noreply, state}

	defp promote(state) do
		case :queue.out(state.waiters) do
			{{:value, {from, pid}}, rest} ->
				ref = Process.monitor(pid)
				GenServer.reply(from, :ok)
				%{state | active: Map.put(state.active, pid, ref), waiters: rest}

			{:empty, _} ->
				state
		end
	end
end

defmodule Contracts.PageWorker do
	use GenServer, restart: :transient

	def start_link({region, page}) do
		GenServer.start_link(__MODULE__, {region, page},
			name: {:via, Registry, {Marketmailer.Registry, {:contract_page, region, page}}}
		)
	end

	def run_round(region, page, round) do
		case Registry.lookup(Marketmailer.Registry, {:contract_page, region, page}) do
			[{pid, _}] -> GenServer.cast(pid, {:run_round, round})
			[] -> :ok
		end
	end

	@impl true
	def init({region, page}) do
		{:ok, %{region: region, page: page, round: nil}}
	end

	@impl true
	def handle_cast({:run_round, round}, state) do
		cond do
			state.round == round ->
				{:noreply, state}

			Marketmailer.Maintenance.down?() ->
				Contracts.RegionManager.page_result(
					state.region,
					round,
					state.page,
					:failed,
					%{reason: :offline}
				)

				Marketmailer.Log.info(
					"contracts_page_offline",
					%{region: state.region, page: state.page, round: round},
					"Contracts #{state.region}/#{state.page}: network down, page skipped"
				)

				{:noreply, %{state | round: nil}}

			true ->
				state = %{state | round: round}
				{status, context} = fetch_and_process(state, round)
				Contracts.RegionManager.page_result(state.region, round, state.page, status, context)
				{:noreply, %{state | round: nil}}
		end
	end

	defp fetch_and_process(%{region: region, page: page}, round) do
		config = Contracts.config()
		url = Contracts.page_url(region, page)
		ESI.wait_for_error_window()

		case ESI.get(url, context: %{region: region, page: page}) do
			{:ok, contracts, ctx} when is_list(contracts) ->
				handle_page_ok(contracts, ctx, region, page, round, config)

			{:ok, _other, _ctx} ->
				{:failed, %{reason: :invalid_body}}

			{:not_modified, ctx} ->
				handle_page_not_modified(ctx, region, page, round, config)

			{:error, :not_found, _ctx} when page >= 2 ->
				{:gone, %{reason: :not_found, pages: page - 1}}

			{:error, :not_found, _ctx} ->
				{:failed, %{reason: :not_found}}

			{:error, :rate_limited, ctx} ->
				{:rate_limited, %{reason: :rate_limited, retry_after_ms: ctx.retry_after_ms}}

			{:error, :service_unavailable, _ctx} ->
				{:failed, %{reason: :service_unavailable}}

			{:error, reason} ->
				{:failed, %{reason: failure_reason(reason)}}
		end
	rescue
		error ->
			Marketmailer.Log.warning(
				"contracts_page_error",
				%{region: region, page: page, reason: Exception.message(error)},
				"Contract page #{region}/#{page} crashed"
			)

			{:failed, %{reason: :page_error}}
	end

	defp handle_page_ok(contracts, ctx, region, page, round, config) do
		now = Contracts.now_ms()

		rows =
			contracts
			|> Enum.filter(&Contracts.candidate?(&1, config, now))
			|> Enum.map(&Contracts.normalize(&1, region, page))

		case Contracts.Database.upsert_page(rows, region, page, round) do
			:ok ->
				persist_etag(ctx)
				if page == 1 and is_integer(ctx.pages), do: Contracts.Database.prune_page_etags(region, ctx.pages)
				items = process_items(region, page, round, config)

				Marketmailer.Log.info(
					"contracts_page_ok",
					%{
						region: region,
						page: page,
						candidates: length(rows),
						pages: ctx.pages,
						item_fetches: items.fetched,
						item_failures: items.failed,
						dropped: items.dropped
					},
					"Contracts #{region}/#{page}: #{length(rows)} candidates"
				)

				{:updated, Map.merge(%{pages: ctx.pages}, items)}

			{:error, error} ->
				{:failed, %{reason: persist_reason(error), pages: ctx.pages}}
		end
	end

	defp handle_page_not_modified(ctx, region, page, round, config) do
		Contracts.Database.mark_page_seen(region, page, round)
		touch_etag(ctx)
		items = process_items(region, page, round, config)
		pages = ctx.pages

		Marketmailer.Log.info(
			"contracts_page_not_modified",
			%{region: region, page: page, pages: pages, item_fetches: items.fetched, item_failures: items.failed},
			"Contracts #{region}/#{page}: not modified"
		)

		{:not_modified, Map.merge(%{pages: pages}, items)}
	end

	defp process_items(region, page, round, config) do
		now = Contracts.now_ms()
		candidates = Contracts.Database.item_candidates(region, page, round, config, now)

		Enum.reduce_while(candidates, %{fetched: 0, failed: 0, dropped: 0}, fn candidate, acc ->
			cond do
				Marketmailer.Maintenance.down?() ->
					{:halt, acc}

				Contracts.Manager.active_round?(round) and
						Contracts.Database.claim_item(candidate.contract_id, round) ->
					result =
						Contracts.ItemGate.run(fn ->
							fetch_items(candidate.contract_id, candidate.items_attempts, config)
						end)

					acc =
						case result do
							:fetched -> %{acc | fetched: acc.fetched + 1}
							:dropped -> %{acc | dropped: acc.dropped + 1}
							{:failed, _reason} -> %{acc | failed: acc.failed + 1}
						end

					{:cont, acc}

				Contracts.Manager.active_round?(round) ->
					{:cont, acc}

				true ->
					{:halt, acc}
			end
		end)
	end

	defp fetch_items(contract_id, attempts, config) do
		if Marketmailer.Maintenance.down?() do
			Contracts.Database.release_item_claim(contract_id)
			{:failed, :offline}
		else
			do_fetch_items(contract_id, attempts, config)
		end
	end

	defp do_fetch_items(contract_id, attempts, config) do
		url = Contracts.items_url(contract_id)
		ESI.wait_for_error_window()

		case ESI.get(url, conditional: false, context: %{contract_id: contract_id}) do
			{:ok, items, _ctx} when is_list(items) ->
				case Contracts.Database.replace_items(contract_id, items) do
					{:ok, _} ->
						:fetched

					{:error, error} ->
						Marketmailer.Log.warning(
							"contracts_item_persist_failed",
							%{contract_id: contract_id, reason: Contracts.error_reason(error), detail: Contracts.error_detail(error)},
							"Contract items persist failed"
						)

						Contracts.Database.mark_item_failed(contract_id, attempts, config)
						{:failed, :persist_failed}
				end

			{:ok, _other, _ctx} ->
				Contracts.Database.mark_item_failed(contract_id, attempts, config)
				{:failed, :invalid_body}

			{:error, :not_found, _ctx} ->
				Contracts.Database.drop_contract(contract_id)
				:dropped

			{:error, :rate_limited, ctx} ->
				Contracts.Database.defer_item(contract_id, max(ctx.retry_after_ms, 1_000))
				{:failed, :rate_limited}

			{:error, reason, _ctx} ->
				Contracts.Database.mark_item_failed(contract_id, attempts, config)
				{:failed, reason}

			{:error, reason} ->
				Contracts.Database.mark_item_failed(contract_id, attempts, config)
				{:failed, reason}

			{:not_modified, _ctx} ->
				Contracts.Database.release_item_claim(contract_id)
				{:failed, :not_modified}
		end
	rescue
		error ->
			Contracts.Database.mark_item_failed(contract_id, attempts, config)
			{:failed, Exception.message(error)}
	end

	defp persist_etag(%{etag: etag} = ctx) when is_binary(etag) do
		case Etag.Database.upsert_etag(ctx.url, etag, Map.get(ctx, :expires_at)) do
			:ok -> :ok
			{:error, _} -> :ok
		end
	end

	defp persist_etag(_ctx), do: :ok

	defp touch_etag(%{etag: etag} = ctx) when is_binary(etag) do
		Etag.Database.touch_cache(ctx.url, etag, Map.get(ctx, :expires_at))
		:ok
	end

	defp touch_etag(_ctx), do: :ok

	defp persist_reason(error) do
		if Database.Writer.disk_full?(error), do: :disk_full, else: :persist_failed
	end

	defp failure_reason(reason) do
		if ESI.network_error?(reason), do: :offline, else: failure_label(reason)
	end

	defp failure_label(%{reason: inner}) when is_atom(inner), do: inner
	defp failure_label(%{__exception__: true} = error), do: Exception.message(error)
	defp failure_label(reason) when is_atom(reason) or is_binary(reason), do: reason
	defp failure_label(reason) when is_integer(reason), do: reason
	defp failure_label(_reason), do: :unknown

	@impl true
	def handle_info(_message, state), do: {:noreply, state}
end

defmodule Contracts.RegionManager do
	use GenServer, restart: :permanent

	@max_page_retries 3
	@retry_margin_ms 30_000

	def start_link(id) when is_integer(id) do
		GenServer.start_link(__MODULE__, id, name: via(id))
	end

	defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:contract_region, id}}}

	def start_round(region, round) when is_integer(region) and is_integer(round) do
		GenServer.cast(via(region), {:start_round, round})
	end

	def page_result(region, round, page, status, context \\ %{}) do
		GenServer.cast(via(region), {:page_result, round, page, status, context})
	end

	def abort(region, round) do
		GenServer.cast(via(region), {:abort, round})
	end

	@impl true
	def init(id) do
		pages = [1 | Contracts.Database.pages_for_region(id)] |> Enum.uniq() |> Enum.sort()
		Enum.each(pages, &start_page(id, &1))

		{:ok,
		 %{
			 id: id,
			 round: nil,
			 expected_pages: Enum.max(pages),
			 results: %{},
			 pages: MapSet.new(pages),
			 retries: %{},
			 timer: nil,
			 item_fetches: 0,
			 item_failures: 0,
			 dropped: 0
		 }}
	end

	@impl true
	def handle_cast({:start_round, round}, state) do
		cancel_timer(state.timer)
		state = %{state | round: round, results: %{}, retries: %{}, item_fetches: 0, item_failures: 0, dropped: 0}
		timeout = Contracts.config() |> Keyword.fetch!(:region_timeout_ms)
		timer = Process.send_after(self(), {:round_timeout, round}, timeout)

		state = reconcile_pages(state, false)
		Enum.each(state.pages, &Contracts.PageWorker.run_round(state.id, &1, round))

		{:noreply, %{state | timer: timer}}
	end

	@impl true
	def handle_cast({:page_result, round, _page, _status, _context}, %{round: current} = state) when round != current do
		{:noreply, state}
	end

	@impl true
	def handle_cast({:page_result, round, page, :gone, context}, state) do
		state = maybe_apply_pages(state, context)
		state = shrink_gone(state, page)
		state = check_cycle(state, round)
		{:noreply, state}
	end

	@impl true
	def handle_cast({:page_result, round, page, :rate_limited, context}, state) do
		retries = Map.get(state.retries, page, 0)
		budget = remaining_ms(state.timer) - @retry_margin_ms

		if retries < @max_page_retries and budget > 0 do
			delay = context |> Map.get(:retry_after_ms, 0) |> max(1_000) |> min(budget)
			Process.send_after(self(), {:retry_page, round, page}, delay)
			{:noreply, %{state | retries: Map.put(state.retries, page, retries + 1)}}
		else
			state = put_result(state, page, :failed, %{reason: :rate_limited})
			{:noreply, check_cycle(state, round)}
		end
	end

	@impl true
	def handle_cast({:page_result, round, page, status, context}, state) do
		state = maybe_apply_pages(state, context)
		state = put_result(state, page, status, context)
		state = check_cycle(state, round)
		{:noreply, state}
	end

	@impl true
	def handle_cast({:abort, round}, %{round: round} = state) do
		state = finish_round(state, round, :aborted)
		{:noreply, state}
	end

	def handle_cast({:abort, _round}, state), do: {:noreply, state}

	@impl true
	def handle_info({:round_timeout, round}, %{round: round} = state) do
		state = finish_round(state, round, :timeout)
		{:noreply, state}
	end

	def handle_info({:round_timeout, _round}, state), do: {:noreply, state}

	def handle_info({:retry_page, round, page}, %{round: round, pages: pages} = state) do
		if MapSet.member?(pages, page) and not Map.has_key?(state.results, page) do
			Contracts.PageWorker.run_round(state.id, page, round)
		end

		{:noreply, state}
	end

	def handle_info({:retry_page, _round, _page}, state), do: {:noreply, state}
	def handle_info(_message, state), do: {:noreply, state}

	defp maybe_apply_pages(state, %{pages: pages}) when is_integer(pages) and pages > 0 do
		apply_count(state, pages)
	end

	defp maybe_apply_pages(state, _context), do: state

	defp apply_count(state, count) do
		count = max(count, 1)
		previous = state.expected_pages
		state = %{state | expected_pages: count}

		state =
			if is_integer(previous) and previous > count do
				%{
					state
					| results: Map.filter(state.results, fn {page, _} -> page <= count end)
				}
			else
				state
			end

		reconcile_pages(state)
	end

	defp put_result(state, page, status, context) do
		result = %{
			status: status,
			reason: Map.get(context, :reason),
			item_fetches: Map.get(context, :fetched, 0),
			item_failures: Map.get(context, :failed, 0),
			dropped: Map.get(context, :dropped, 0)
		}

		%{
			state
			| results: Map.put(state.results, page, result),
				item_fetches: state.item_fetches + result.item_fetches,
				item_failures: state.item_failures + result.item_failures,
				dropped: state.dropped + result.dropped
		}
	end

	defp shrink_gone(state, page) when page < 2 do
		state
		|> apply_count(1)
		|> put_result(1, :failed, %{reason: :not_found})
	end

	defp shrink_gone(state, page) do
		expected = state.expected_pages

		if is_integer(expected) and page - 1 >= expected do
			state
		else
			state
			|> apply_count(page - 1)
			|> then(fn state ->
				stop_page(state.id, page)
				%{state | pages: MapSet.delete(state.pages, page)}
			end)
		end
	end

	defp check_cycle(%{round: nil} = state, _round), do: state

	defp check_cycle(%{expected_pages: expected} = state, round) when is_integer(expected) do
		if Enum.all?(1..expected, &Map.has_key?(state.results, &1)) do
			finish_round(state, round, :complete)
		else
			state
		end
	end

	defp check_cycle(state, _round), do: state

	defp finish_round(%{round: round} = state, round, reason) do
		cancel_timer(state.timer)
		pages = state.expected_pages || 1

		page_failures =
			for {page, %{status: :failed, reason: failure_reason}} <- state.results,
					do: %{page: page, reason: failure_reason}

		missing_failures =
			for page <- 1..pages,
					not Map.has_key?(state.results, page),
					do: %{page: page, reason: reason}

		failures = page_failures ++ missing_failures

		summary = %{
			region: state.id,
			round: round,
			pages: pages,
			updated_pages: for({page, %{status: :updated}} <- state.results, do: page),
			failures: failures,
			item_fetches: state.item_fetches,
			item_failures: state.item_failures,
			dropped: state.dropped
		}

		event = if failures == [], do: "contracts_region_complete", else: "contracts_region_failed"

		if failures == [] do
			Marketmailer.Log.info(
				event,
				summary,
				"Contracts region #{state.id} round complete"
			)
		else
			Marketmailer.Log.warning(
				event,
				summary,
				"Contracts region #{state.id} round had failures"
			)
		end

		Contracts.Manager.region_complete(round, summary)

		%{state | round: nil, results: %{}, retries: %{}, timer: nil}
	end

	defp finish_round(state, _round, _reason), do: state

	defp reconcile_pages(state, trigger? \\ true) do
		expected = state.expected_pages || 1
		wanted = MapSet.new(1..expected)

		live =
			Enum.reduce(wanted, MapSet.new(), fn page, acc ->
				if Registry.lookup(Marketmailer.Registry, {:contract_page, state.id, page}) == [] do
					acc
				else
					MapSet.put(acc, page)
				end
			end)

		missing = MapSet.difference(wanted, live)
		extra = MapSet.difference(state.pages, wanted)

		Enum.each(missing, fn page ->
			start_page(state.id, page)
			if trigger? and is_integer(state.round), do: Contracts.PageWorker.run_round(state.id, page, state.round)
		end)

		Enum.each(extra, &stop_page(state.id, &1))

		%{state | pages: wanted}
	end

	defp start_page(id, page) do
		case Registry.lookup(Marketmailer.Registry, {:contract_page, id, page}) do
			[] ->
				DynamicSupervisor.start_child(
					Contracts.PageSup,
					{Contracts.PageWorker, {id, page}}
				)

			_ ->
				:ok
		end
	end

	defp stop_page(id, page) do
		for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:contract_page, id, page}),
				do: DynamicSupervisor.terminate_child(Contracts.PageSup, pid)
	end

	defp cancel_timer(nil), do: :ok
	defp cancel_timer(ref), do: Process.cancel_timer(ref)

	defp remaining_ms(nil), do: 0

	defp remaining_ms(ref) do
		case Process.read_timer(ref) do
			ms when is_integer(ms) -> ms
			_ -> 0
		end
	end
end

defmodule Contracts.RegionManagerSupervisor do
	use Supervisor

	def start_link(_opts), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_opts) do
		regions = Marketmailer.RegionManagerSupervisor.region_ids()

		if regions == [] do
			Marketmailer.Log.warning(
				"contracts_regions_missing",
				%{},
				"no SDE regions loaded; starting no contract region managers"
			)
		else
			Marketmailer.Log.info(
				"contracts_regions_loaded",
				%{regions: length(regions)},
				"starting one contract region manager per SDE region"
			)
		end

		children =
			for id <- regions do
				Supervisor.child_spec({Contracts.RegionManager, id}, id: {:contract_region_manager, id})
			end

		Supervisor.init(children, strategy: :one_for_one)
	end
end

defmodule Contracts.Manager do
	use GenServer

	@active_round_key {Contracts, :active_round}

	def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

	def active_round?(round) do
		case :persistent_term.get(@active_round_key, nil) do
			^round -> true
			_ -> false
		end
	end

	def region_complete(round, summary) do
		if pid = Process.whereis(__MODULE__), do: send(pid, {:contracts_region_complete, round, summary})
		:ok
	end

	@impl true
	def init(_opts) do
		:persistent_term.erase(@active_round_key)
		config = Contracts.config()
		delay = Keyword.fetch!(config, :initial_delay_ms) + :rand.uniform(5_000)
		Process.send_after(self(), :start_round, delay)
		Marketmailer.Maintenance.subscribe(self())

		{:ok,
		 %{
			 config: config,
			 round: nil,
			 queue: [],
			 active: %{},
			 results: %{},
			 started_at: nil,
			 deadline_timer: nil,
			 paused: false
		 }}
	end

	@impl true
	def handle_info(:start_round, %{round: round} = state) when not is_nil(round) do
		{:noreply, state}
	end

	@impl true
	def handle_info(:start_round, state) do
		if Marketmailer.Maintenance.down?() do
			state = note_paused(state)
			Process.send_after(self(), :start_round, Keyword.fetch!(state.config, :pause_recheck_ms))
			{:noreply, state}
		else
			regions = Marketmailer.RegionManagerSupervisor.region_ids()

			if regions == [] do
				Marketmailer.Log.warning(
					"contracts_round_skipped",
					%{reason: :regions_missing},
					"Contract round skipped: no SDE regions loaded"
				)

				Process.send_after(self(), :start_round, 300_000)
				{:noreply, state}
			else
				round = System.unique_integer([:positive, :monotonic])
				:persistent_term.put(@active_round_key, round)

				deadline =
					Process.send_after(self(), {:round_deadline, round}, Keyword.fetch!(state.config, :round_deadline_ms))

				Marketmailer.Log.info(
					"contracts_round_started",
					%{round: round, regions: length(regions)},
					"Contract round #{round} started across #{length(regions)} regions"
				)

				state = %{
					state
					| round: round,
						queue: regions,
						active: %{},
						results: %{},
						started_at: Contracts.now_ms(),
						deadline_timer: deadline,
						paused: false
				}

				state = dispatch(state) |> maybe_finalize()
				{:noreply, state}
			end
		end
	end

	def handle_info({:contracts_region_complete, round, summary}, %{round: round} = state) do
		region = summary.region

		state = %{
			state
			| active: Map.delete(state.active, region),
				results: Map.put(state.results, region, summary)
		}

		state = dispatch(state)
		{:noreply, maybe_finalize(state)}
	end

	def handle_info({:contracts_region_complete, _round, _summary}, state), do: {:noreply, state}

	def handle_info({:round_deadline, round}, %{round: round} = state) do
		Marketmailer.Log.warning(
			"contracts_round_deadline",
			%{round: round, active: map_size(state.active), results: map_size(state.results)},
			"Contract round reached its deadline; finalizing with partial results"
		)

		Enum.each(Map.keys(state.active), &Contracts.RegionManager.abort(&1, round))
		{:noreply, finalize(%{state | active: %{}, queue: []})}
	end

	def handle_info({:round_deadline, _round}, state), do: {:noreply, state}

	def handle_info({:maintenance, :down}, %{round: round} = state) when not is_nil(round) do
		Marketmailer.Log.info(
			"contracts_round_paused",
			%{round: round, active: map_size(state.active)},
			"Contract round #{round} paused: network down"
		)

		Enum.each(Map.keys(state.active), &Contracts.RegionManager.abort(&1, round))
		cancel_timer(state.deadline_timer)
		:persistent_term.erase(@active_round_key)
		Process.send_after(self(), :start_round, Keyword.fetch!(state.config, :pause_recheck_ms))

		{:noreply,
		 %{
			 state
			 | round: nil,
				 queue: [],
				 active: %{},
				 results: %{},
				 started_at: nil,
				 deadline_timer: nil,
				 paused: true
		 }}
	end

	def handle_info({:maintenance, :down}, state), do: {:noreply, %{state | paused: true}}

	def handle_info({:maintenance, :up}, %{round: nil} = state) do
		send(self(), :start_round)
		{:noreply, %{state | paused: false}}
	end

	def handle_info({:maintenance, :up}, state), do: {:noreply, state}
	def handle_info(_message, state), do: {:noreply, state}

	defp note_paused(%{paused: true} = state), do: state

	defp note_paused(state) do
		Marketmailer.Log.info(
			"contracts_round_paused",
			%{reason: "network"},
			"Contract rounds paused while the network is down"
		)

		%{state | paused: true}
	end

	defp dispatch(state) do
		max_regions = Keyword.fetch!(state.config, :region_concurrency)
		now = Contracts.now_ms()

		state =
			Enum.reduce_while(1..max_regions, state, fn _, state ->
				cond do
					map_size(state.active) >= max_regions ->
						{:halt, state}

					state.queue == [] ->
						{:halt, state}

					true ->
						[region | rest] = state.queue
						state = %{state | queue: rest}

						case Registry.lookup(Marketmailer.Registry, {:contract_region, region}) do
							[{_pid, _}] ->
								Contracts.RegionManager.start_round(region, state.round)
								{:cont, %{state | active: Map.put(state.active, region, now)}}

							[] ->
								summary = %{
									region: region,
									round: state.round,
									pages: 0,
									updated_pages: [],
									failures: [%{page: 1, reason: :region_missing}],
									item_fetches: 0,
									item_failures: 0,
									dropped: 0
								}

								{:cont, %{state | results: Map.put(state.results, region, summary)}}
						end
				end
			end)

		state
	end

	defp maybe_finalize(%{queue: [], active: active} = state) when map_size(active) == 0 do
		finalize(state)
	end

	defp maybe_finalize(state), do: state

	defp finalize(%{round: round} = state) do
		cancel_timer(state.deadline_timer)
		:persistent_term.erase(@active_round_key)

		try do
			Contracts.Broadcast.finalize(round, state.results, state.config)
		rescue
			error ->
				Marketmailer.Log.error(
					"contracts_round_finalize_failed",
					%{round: round, reason: Exception.message(error)},
					"Contract round finalize failed"
				)
		catch
			_, reason ->
				Marketmailer.Log.error(
					"contracts_round_finalize_failed",
					%{round: round, reason: inspect(reason)},
					"Contract round finalize failed"
				)
		end

		now = Contracts.now_ms()
		period = Keyword.fetch!(state.config, :period_ms)
		next_at = max((state.started_at || now) + period, now + 30_000)
		delay = max(next_at - now, 30_000)
		Process.send_after(self(), :start_round, delay)

		%{
			state
			| round: nil,
				queue: [],
				active: %{},
				results: %{},
				started_at: nil,
				deadline_timer: nil,
				paused: state.paused
		}
	end

	defp cancel_timer(nil), do: :ok
	defp cancel_timer(ref), do: Process.cancel_timer(ref)
end

defmodule Contracts.Broadcast do
	alias Contracts.Database
	alias Discord.Embeds

	@top_round_key {Contracts, :top_round}
	@round_stats_key {Contracts, :round_stats}
	@top_contracts_key {Contracts, :top_contracts}

	def finalize(round, results, config) do
		limit = Keyword.fetch!(config, :broadcast_limit)
		top = load_top(round, limit, config)
		:persistent_term.put(@top_round_key, round)
		:persistent_term.put(@top_contracts_key, {round, top})
		:persistent_term.put(@round_stats_key, stats(results, round, length(top)))

		payload = Embeds.contract_list_payload(top, 1, config)
		delivered = deliver(payload)

		Marketmailer.Log.info(
			"contracts_round_complete",
			%{
				round: round,
				regions: map_size(results),
				failed_regions: Enum.count(results, fn {_region, summary} -> summary.failures != [] end),
				desired: length(top),
				delivered: delivered
			},
			"Contract round #{round} complete with #{length(top)} desired contract(s)"
		)

		Contracts.Database.prune(Keyword.fetch!(config, :prune_grace_ms))
		:ok
	end

	def command_payload do
		config = Contracts.config()
		round = current_round()

		if is_integer(round) do
			Embeds.contract_list_payload(resolve_top(round, config), 1, config)
		else
			Embeds.contract_list_empty_payload("No contract round has completed yet.")
		end
	rescue
		_ -> Embeds.contract_list_error_payload()
	end

	def page_payload(page) do
		config = Contracts.config()
		round = current_round()

		if is_integer(round) do
			Embeds.contract_list_payload(resolve_top(round, config), page, config)
		else
			Embeds.contract_list_empty_payload("No contract round has completed yet.")
		end
	rescue
		_ -> Embeds.contract_list_error_payload()
	end

	def current_round do
		case :persistent_term.get(@top_round_key, nil) do
			nil -> Database.latest_round()
			round -> round
		end
	end

	defp load_top(round, limit, config) do
		top = Database.top_desired(round, limit, Keyword.fetch!(config, :min_margin))
		names = Database.item_names(Enum.map(top, & &1.contract_id))

		Enum.map(top, fn contract ->
			Map.put(contract, :item_names, Map.get(names, contract.contract_id, []))
		end)
	end

	defp resolve_top(round, config) do
		limit = Keyword.fetch!(config, :broadcast_limit)

		case :persistent_term.get(@top_contracts_key, nil) do
			{^round, top} when is_list(top) -> Enum.take(top, limit)
			_ -> load_top(round, limit, config)
		end
	end

	defp stats(results, round, desired) do
		%{
			round: round,
			regions: map_size(results),
			failed_regions: Enum.count(results, fn {_region, summary} -> summary.failures != [] end),
			desired: desired
		}
	end

	defp deliver(payload) do
		channels = Discord.Database.registered_channels() |> Enum.uniq()
		payload = Map.put(payload, :allowed_mentions, :none)

		if channels == [] do
			Marketmailer.Log.info(
				"contracts_broadcast_no_channels",
				%{},
				"Contract digest skipped: no registered Discord channels"
			)

			0
		else
			delivered =
				Enum.count(channels, fn channel ->
					case Discord.Broadcaster.deliver(channel, payload) do
						{:ok, _message} -> true
						_ -> false
					end
				end)

			Marketmailer.Log.info(
				"contracts_broadcast_delivered",
				%{channels: delivered},
				"Contract digest delivered to #{delivered} channel(s)"
			)

			delivered
		end
	rescue
		error ->
			Marketmailer.Log.warning(
				"contracts_broadcast_failed",
				%{reason: Exception.message(error)},
				"Contract digest delivery failed"
			)

			0
	end
end
