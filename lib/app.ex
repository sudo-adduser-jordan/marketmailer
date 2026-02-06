defmodule Marketmailer.Application do
  use Application

  @user_agent "lostcoastwizard > BEAM me up, Scotty!"
  @regions Enum.concat([
             10_000_001..10_000_070,
             [10_001_000],
             11_000_001..11_000_033,
             12_000_001..12_000_005,
             14_000_001..14_000_005,
             [19_000_001]
           ])
           |> Enum.to_list()

  def user_agent, do: @user_agent
  def regions, do: @regions

  @impl true
  def start(_type, _args) do
    :ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])

    children = [
      Marketmailer.Database,
      {Registry, keys: :unique, name: Marketmailer.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
      {Task.Supervisor, name: Marketmailer.TaskSup},
      Marketmailer.RegionManagerSupervisor,
      Marketmailer.EtagWarmup
    ]

    opts = [
      strategy: :one_for_one,
      name: Marketmailer.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end
end

defmodule Marketmailer.RegionManagerSupervisor do
  use Supervisor
  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    children =
      for id <- Marketmailer.Application.regions(),
          do: Supervisor.child_spec({Marketmailer.RegionManager, id}, id: {:region_manager, id})

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Marketmailer.RegionManager do
  use GenServer, restart: :permanent
  require Logger

  def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))
  defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

  @impl true
  def init(id) do
    start_page(id, 1)
    {:ok, %{id: id, page_count: 1}}
  end

  @impl true
  def handle_info({:update_page_count, count}, %{id: id, page_count: old} = state) do
    count = max(count, 1)

    if count != old do
      Logger.debug("Region #{id}: pages #{old} -> #{count}")
      adjust_workers(id, old, count)
      {:noreply, %{state | page_count: count}}
    else
      {:noreply, state}
    end
  end

  defp adjust_workers(id, old, new) do
    cond do
      new > old -> Enum.each((old + 1)..new, &start_page(id, &1))
      new < old -> Enum.each((new + 1)..old, &stop_page(id, &1))
      true -> :ok
    end
  end

  defp start_page(id, p),
    do: DynamicSupervisor.start_child(Marketmailer.PageSup, {Marketmailer.PageWorker, {self(), id, p}})

  defp stop_page(id, p) do
    for {pid, _} <- Registry.lookup(Marketmailer.Registry, {:page, id, p}),
        do: GenServer.stop(pid, :normal)
  end
end

defmodule Marketmailer.PageWorker do
  use GenServer, restart: :transient
  require Logger

  def start_link({mgr, id, page}),
    do:
      GenServer.start_link(__MODULE__, {mgr, id, page},
        name: {:via, Registry, {Marketmailer.Registry, {:page, id, page}}}
      )

  @impl true
  def init({mgr, id, page}) do
    send(self(), :work)
    {:ok, %{mgr: mgr, id: id, page: page, errors: 0}}
  end

  @impl true
  def handle_info(:work, state) do
    %{mgr: mgr, id: id, page: page, errors: errs} = state
    Marketmailer.ESI.wait_for_error_window()

    new_state =
      case Marketmailer.ESI.fetch(id, page) do
        {:ok, data, ctx} ->
          Logger.info("200 #{id} #{length(data)} \t #{format_ttl(ctx.ttl)} \t #{ctx.url}")
          Marketmailer.Database.upsert_orders(data)
          Marketmailer.Database.upsert_etag(ctx.url, ctx.etag)
          notify_and_reschedule(mgr, ctx.pages, ctx.ttl, %{state | errors: 0})

        {:not_modified, ctx} ->
          Logger.info("304 #{id}     \t #{format_ttl(ctx.ttl)} \t #{ctx.url}")
          Marketmailer.Database.upsert_etag(ctx.url, ctx.etag)
          notify_and_reschedule(mgr, ctx.pages, ctx.ttl, %{state | errors: 0})

        {:error, reason} ->
          delay = backoff_ms(errs)
          Logger.warning("Fetch error for region #{id} page #{page}: #{inspect(reason)}; retry in #{div(delay, 1000)}s")
          schedule_next(delay)
          %{state | errors: errs + 1}
      end

    {:noreply, new_state}
  end

  defp notify_and_reschedule(mgr, count, ttl, state) do
    send(mgr, {:update_page_count, count})
    schedule_next(ttl)
    state
  end

  defp schedule_next(ms), do: Process.send_after(self(), :work, ms)
  defp backoff_ms(errors), do: min((60_000 * :math.pow(2, errors)) |> round, 300_000)

  defp format_ttl(ttl_ms) do
    total_seconds = div(ttl_ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    min = String.pad_leading("#{minutes}", 2, "0")
    sec = String.pad_leading("#{seconds}", 2, "0")

    "#{min}:#{sec}"
  end
end

defmodule Marketmailer.ESI do
  require Logger
  @error_limit_threshold 100
  @pause_ms 61_000
  @table :esi_error_state
  @key :blocked_until

  def wait_for_error_window do
    now = System.system_time(:millisecond)

    case :ets.lookup(@table, @key) do
      [{@key, t}] when t > now ->
        sleep = t - now
        Logger.warning("ESI limit low, pausing #{div(sleep, 1000)}s")
        Process.sleep(sleep)

      _ ->
        :ok
    end
  end

  def fetch(region, page \\ 1) do
    url = "https://esi.evetech.net/v1/markets/#{region}/orders/?page=#{page}"
    etag = Marketmailer.Database.get_etag(url)

    headers =
      [{"User-Agent", Marketmailer.Application.user_agent()}] ++ if etag, do: [{"If-None-Match", etag}], else: []

    case Req.get(url, headers: headers, pool_timeout: 69420) do
      {:ok, %{status: 200} = r} ->
        {:ok, r.body, meta(r, url)}

      {:ok, %{status: 304} = r} ->
        {:not_modified, meta(r, url)}

      {:ok, r} ->
        _ = meta(r, url)
        {:error, r.status}

      {:error, e} ->
        Logger.error("#{region}/#{page} HTTP error: #{inspect(e)}")
        {:error, e}
    end
  end

  defp meta(r, url) do
    error_rem = first(r.headers, "x-esi-error-limit-remain")
    ttl = calc_ttl(first(r.headers, "expires"))
    ttl = if remain(error_rem) < @error_limit_threshold, do: enforce_pause(ttl), else: ttl

    %{
      url: url,
      etag: first(r.headers, "etag"),
      ttl: ttl,
      pages: String.to_integer(first(r.headers, "x-pages") || "1")
    }
  end

  defp remain(nil), do: 999
  defp remain(v), do: Integer.parse(v) |> elem(0)
  defp first(h, k), do: Map.get(h, k, []) |> List.first()

  defp enforce_pause(ttl) do
    now = System.system_time(:millisecond)
    :ets.insert(@table, {@key, now + @pause_ms})
    max(ttl, @pause_ms)
  end

  defp calc_ttl(nil), do: 60_000

  defp calc_ttl(exp) do
    with {{_, _, _}, {_, _, _}} = erl <- :httpd_util.convert_request_date(to_charlist(exp)),
         dt <- DateTime.from_naive!(NaiveDateTime.from_erl!(erl), "Etc/UTC") do
      max(DateTime.diff(dt, DateTime.utc_now(), :millisecond), 5_000) + 1_000
    else
      _ -> 60_000
    end
  end
end

defmodule Marketmailer.Database do
  use Ecto.Repo, otp_app: :marketmailer, adapter: Ecto.Adapters.Postgres
  import Ecto.Query

  @fields ~w(order_id duration is_buy_order issued location_id min_volume price range system_id type_id volume_remain volume_total inserted_at updated_at)a

  def upsert_orders([]), do: :ok

  def upsert_orders(orders) do
    ts = NaiveDateTime.utc_now(:second)

    rows =
      for o <- orders do
        base = for f <- @fields, into: %{}, do: {f, o[Atom.to_string(f)]}
        Map.merge(base, %{inserted_at: ts, updated_at: ts})
      end

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

  def upsert_etag(nil, _), do: :ok
  def upsert_etag(_, nil), do: :ok

  def upsert_etag(url, etag) do
    now = NaiveDateTime.utc_now(:second)

    insert_all(Etag, [%{url: url, etag: etag, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:etag, :updated_at]},
      conflict_target: :url
    )

    :ets.insert(:market_cache, {url, etag})
  end
end

defmodule Market do
  use Ecto.Schema

  schema "market" do
    field :duration, :integer
    field :is_buy_order, :boolean
    field :issued, :string
    field :location_id, :integer
    field :min_volume, :integer
    field :order_id, :integer
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
