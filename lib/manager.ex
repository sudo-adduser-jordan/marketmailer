defmodule Marketmailer.RegionManager do
	@moduledoc """
	One sequential worker per region.

	Fetches pages 1..N in order inside a single `:work` cycle instead of
	fanning out one `PageWorker` per page. This keeps ESI concurrency at
	~1 request per region and removes the overlapping-cycle race that
	caused spurious `cycle_timeout` failures.
	"""

	use GenServer, restart: :permanent

	@ping_interval 10_000

	def start_link(id) when is_integer(id), do: start_link({id, []})

	def start_link({id, opts}) do
		GenServer.start_link(__MODULE__, {id, opts}, name: via(id))
	end

	defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

	@impl true
	def init({id, opts}) do
		# Jitter initial sweep so all ~115 regions don't hit ESI at once on boot.
		delay = :erlang.phash2(id, 5_000)

		state = %{
			id: id,
			errors: 0,
			fetch_fun: Keyword.get(opts, :fetch_fun, &ESI.fetch/2),
			persist_fun: Keyword.get(opts, :persist_fun, &persist/2),
			coordinator: Keyword.get(opts, :coordinator, Market.UpdateCoordinator)
		}

		Process.send_after(self(), :work, delay)
		{:ok, state}
	end

	@impl true
	def handle_info(:work, state) do
		if ESI.maintenance_active?() do
			schedule_next(@ping_interval)
			{:noreply, state}
		else
			{:noreply, sweep(state)}
		end
	end

	defp sweep(%{id: id, coordinator: coord} = state) do
		ESI.wait_for_error_window()

		case safe_fetch(state, 1) do
			{:ok, _data, ctx} ->
				total = max(ctx.pages, 1)
				Market.UpdateCoordinator.page_started(id, 1, coord)
				report(state, 1, :ok, ctx)
				{failures, ttl} = fetch_rest(state, 2, total, ctx.ttl)

				Market.UpdateCoordinator.page_count(id, total, coord)
				emit_cycle(state, total, failures)
				schedule_next(max(ttl, 5_000))
				%{state | errors: 0}

			{:not_modified, ctx} ->
				total = max(ctx.pages, 1)
				Market.UpdateCoordinator.page_started(id, 1, coord)
				report(state, 1, :not_modified, ctx)
				{failures, _ttl} = fetch_rest(state, 2, total, ctx.ttl)

				Market.UpdateCoordinator.page_count(id, total, coord)
				emit_cycle(state, total, failures)
				schedule_next(max(ctx.ttl, 5_000))
				%{state | errors: 0}

			{:error, :service_unavailable, ctx} ->
				Marketmailer.Log.info(
					"page_fetch_unavailable",
					%{region: id, page: 1, status: 503, url: ctx.url},
					"503 #{id} #{ctx.url}"
				)

				Market.UpdateCoordinator.page_started(id, 1, coord)
				Market.UpdateCoordinator.page_result(id, 1, :failed, %{reason: :service_unavailable}, coord)
				schedule_next(@ping_interval)
				state

			{:error, :rate_limited, ctx} ->
				Marketmailer.Log.warning(
					"page_fetch_rate_limited",
					%{region: id, page: 1, status: 429, retry_after_ms: ctx.retry_after_ms, url: ctx.url},
					"429 #{id} retry in #{ctx.retry_after_ms}ms #{ctx.url}"
				)

				Market.UpdateCoordinator.page_started(id, 1, coord)
				Market.UpdateCoordinator.page_result(id, 1, :failed, %{reason: :rate_limited}, coord)
				schedule_next(max(ctx.retry_after_ms, 1_000))
				%{state | errors: 0}

			{:error, reason} ->
				delay = backoff_ms(state.errors)

				Marketmailer.Log.warning(
					"page_fetch_error",
					%{region: id, page: 1, reason: inspect(reason), retry_in_ms: delay},
					"Fetch error for region #{id} page 1: #{inspect(reason)}"
				)

				Market.UpdateCoordinator.page_started(id, 1, coord)
				Market.UpdateCoordinator.page_result(id, 1, :failed, %{reason: failure_reason(reason)}, coord)
				schedule_next(delay)
				%{state | errors: state.errors + 1}
		end
	end

	# Pages 2..N, strictly sequential. Returns {failures, max_ttl}.
	defp fetch_rest(_state, first, last, ttl) when first > last, do: {[], ttl}

	defp fetch_rest(%{id: id, coordinator: coord} = state, page, total, ttl) do
		Enum.reduce_while(page..total//1, {[], ttl}, fn p, {failures, best_ttl} ->
			ESI.wait_for_error_window()
			Market.UpdateCoordinator.page_started(id, p, coord)

			case safe_fetch(state, p) do
				{:ok, _data, ctx} ->
					report(state, p, :ok, ctx)
					{:cont, {failures, max(best_ttl, ctx.ttl)}}

				{:not_modified, ctx} ->
					report(state, p, :not_modified, ctx)
					{:cont, {failures, max(best_ttl, ctx.ttl)}}

				{:error, :service_unavailable, _ctx} ->
					Market.UpdateCoordinator.page_result(id, p, :failed, %{reason: :service_unavailable}, coord)
					{:halt, {[{p, :service_unavailable} | failures], best_ttl}}

				{:error, :rate_limited, ctx} ->
					Market.UpdateCoordinator.page_result(id, p, :failed, %{reason: :rate_limited}, coord)
					{:halt, {[{p, :rate_limited} | failures], max(best_ttl, max(ctx.retry_after_ms, 1_000))}}

				{:error, reason} ->
					Market.UpdateCoordinator.page_result(id, p, :failed, %{reason: failure_reason(reason)}, coord)
					{:cont, {[{p, failure_reason(reason)} | failures], best_ttl}}
			end
		end)
	end

	# Never let a persist/DB crash kill the cycle without a coordinator report.
	defp report(%{id: id, coordinator: coord, persist_fun: persist}, page, kind, ctx) do
		status = if kind == :ok, do: :updated, else: :not_modified

		try do
			case kind do
				:ok -> persist.(page, ctx)
				:not_modified -> if ctx.etag, do: Etag.Database.upsert_etag(ctx.url, ctx.etag)
			end

			Marketmailer.Log.info(
				"page_fetch_ok",
				%{region: id, page: page, status: if(kind == :ok, do: 200, else: 304), ttl_ms: ctx.ttl, url: ctx.url},
				"#{id}/#{page} #{if(kind == :ok, do: 200, else: 304)} #{ctx.url}"
			)

			Market.UpdateCoordinator.page_result(id, page, status, %{pages: ctx.pages}, coord)
		rescue
			e ->
				Marketmailer.Log.warning(
					"page_persist_failed",
					%{region: id, page: page, reason: Exception.message(e)},
					"Persist failed for region #{id} page #{page}"
				)

				Market.UpdateCoordinator.page_result(id, page, :failed, %{reason: :persist_failed}, coord)
		end
	end

	defp persist(_page, ctx) do
		# Placeholder replaced by injected persist_fun in tests; production path
		# fetches body via ESI and upserts here. The real fetch_fun returns
		# {:ok, data, ctx}; persist both orders and etag.
		:ok = persist_orders(ctx)
	end

	defp persist_orders(%{url: url, etag: etag} = ctx) do
		if Map.has_key?(ctx, :orders) do
			Market.Database.upsert_orders(ctx.orders)
		end

		if etag, do: Etag.Database.upsert_etag(url, etag)
		:ok
	end

	# Fetch wrapper that attaches the body for persist without changing ESI.fetch.
	defp safe_fetch(%{id: id, fetch_fun: fetch}, page) do
		case fetch.(id, page) do
			{:ok, data, ctx} -> {:ok, data, ctx |> Map.put(:orders, data)}
			other -> other
		end
	rescue
		e -> {:error, e}
	catch
		:exit, reason -> {:error, {:exit, reason}}
	end

	defp emit_cycle(%{id: id}, total, failures) do
		if failures != [] do
			Marketmailer.Log.warning(
				"region_sweep_partial",
				%{region: id, pages: total, failed: length(failures)},
				"Region #{id} sweep partial: #{length(failures)}/#{total} pages failed"
			)
		end
	end

	defp schedule_next(ms), do: Process.send_after(self(), :work, ms)
	defp backoff_ms(errors), do: (60_000 * :math.pow(2, errors)) |> round() |> min(300_000)

	defp failure_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
	defp failure_reason(reason) when is_integer(reason), do: reason
	defp failure_reason(_reason), do: :unknown

	def format_ttl(ttl_ms) do
		total_seconds = div(ttl_ms, 1_000)
		minutes = div(total_seconds, 60)
		seconds = rem(total_seconds, 60)
		"#{String.pad_leading("#{minutes}", 2, "0")}:#{String.pad_leading("#{seconds}", 2, "0")}"
	end
end
