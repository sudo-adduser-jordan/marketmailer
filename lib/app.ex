defmodule Marketmailer.Application do
  use Application

  @user_agent "lostcoastwizard > BEAM me up, Scotty!"
  @regions [
    10_000_001,
    10_000_002,
    10_000_003,
    10_000_004,
    10_000_005,
    10_000_006,
    10_000_007,
    10_000_008,
    10_000_009,
    10_000_010,
    10_000_011,
    10_000_012,
    10_000_013,
    10_000_014,
    10_000_015,
    10_000_016,
    10_000_017,
    10_000_018,
    10_000_019,
    10_000_020,
    10_000_021,
    10_000_022,
    10_000_023,
    10_000_025,
    10_000_027,
    10_000_028,
    10_000_029,
    10_000_030,
    10_000_031,
    10_000_032,
    10_000_033,
    10_000_034,
    10_000_035,
    10_000_036,
    10_000_037,
    10_000_038,
    10_000_039,
    10_000_040,
    10_000_041,
    10_000_042,
    10_000_043,
    10_000_044,
    10_000_045,
    10_000_046,
    10_000_047,
    10_000_048,
    10_000_049,
    10_000_050,
    10_000_051,
    10_000_052,
    10_000_053,
    10_000_054,
    10_000_055,
    10_000_056,
    10_000_057,
    10_000_058,
    10_000_059,
    10_000_060,
    10_000_061,
    10_000_062,
    10_000_063,
    10_000_064,
    10_000_065,
    10_000_066,
    10_000_067,
    10_000_068,
    10_000_069,
    10_000_070,
    10_001_000,
    11_000_001,
    11_000_002,
    11_000_003,
    11_000_004,
    11_000_005,
    11_000_006,
    11_000_007,
    11_000_008,
    11_000_009,
    11_000_010,
    11_000_011,
    11_000_012,
    11_000_013,
    11_000_014,
    11_000_015,
    11_000_016,
    11_000_017,
    11_000_018,
    11_000_019,
    11_000_020,
    11_000_021,
    11_000_022,
    11_000_023,
    11_000_024,
    11_000_025,
    11_000_026,
    11_000_027,
    11_000_028,
    11_000_029,
    11_000_030,
    11_000_031,
    11_000_032,
    11_000_033,
    12_000_001,
    12_000_002,
    12_000_003,
    12_000_004,
    12_000_005,
    14_000_001,
    14_000_002,
    14_000_003,
    14_000_004,
    14_000_005,
    19_000_001
  ]

  def user_agent, do: @user_agent
  def regions, do: @regions

  @impl true
  def start(_type, _args) do
    # Optional:  memory cache ETS in front of DB
    :ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])

    children = [
      Marketmailer.Database,
      {Registry, keys: :unique, name: Marketmailer.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
      {Task.Supervisor, name: Marketmailer.TaskSup},
      Marketmailer.RegionManagerSupervisor,
      Marketmailer.EtagWarmup
    ]

    opts = [strategy: :one_for_one, name: Marketmailer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule Marketmailer.RegionManagerSupervisor do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      for region_id <- Marketmailer.Application.regions() do
        Supervisor.child_spec(
          {Marketmailer.RegionManager, region_id},
          id: {:region_manager, region_id}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Marketmailer.RegionManager do
  use GenServer
  require Logger

  @moduledoc false

  def start_link(region_id),
    do: GenServer.start_link(__MODULE__, region_id, name: via(region_id))

  defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

  @impl true
  def init(id) do
    # start page 1 immediately, pass our pid as manager
    {:ok, _} =
      DynamicSupervisor.start_child(
        Marketmailer.PageSup,
        {Marketmailer.PageWorker, {self(), id, 1}}
      )

    {:ok, %{id: id, page_count: 1}}
  end

  @impl true
  def handle_info({:update_page_count, new_count}, %{id: id, page_count: current} = state) do
    # Never drop below 1 page, even if ESI says 0
    new_count = max(new_count, 1)

    if new_count != current do
      Logger.debug("Region #{id}: pages #{current} -> #{new_count}")
      adjust_workers(id, current, new_count)
      {:noreply, %{state | page_count: new_count}}
    else
      {:noreply, state}
    end
  end

  defp adjust_workers(id, old, new) when new > old do
    for p <- (old + 1)..new do
      spec = {Marketmailer.PageWorker, {self(), id, p}}

      case DynamicSupervisor.start_child(Marketmailer.PageSup, spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to start page worker #{id}/#{p}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp adjust_workers(id, old, new) when new < old do
    for p <- (new + 1)..old do
      key = {:page, id, p}

      case Registry.lookup(Marketmailer.Registry, key) do
        [{pid, _meta}] ->
          Logger.debug("Stopping worker for region #{id} page #{p}")
          GenServer.stop(pid, :normal)

        [] ->
          :ok
      end
    end

    :ok
  end

  defp adjust_workers(_id, _old, _new), do: :ok
end

defmodule Marketmailer.PageWorker do
  use GenServer, restart: :transient
  require Logger

  @moduledoc false

  def start_link({manager_pid, region_id, page}),
    do:
      GenServer.start_link(__MODULE__, {manager_pid, region_id, page}, name: via(region_id, page))

  defp via(region_id, page),
    do: {:via, Registry, {Marketmailer.Registry, {:page, region_id, page}}}

  @impl true
  def init({manager_pid, region_id, page}) do
    send(self(), :work)

    {:ok,
     %{
       manager: manager_pid,
       region_id: region_id,
       page: page,
       errors: 0
     }}
  end

  @impl true
  def handle_info(
        :work,
        %{manager: manager, region_id: region_id, page: page, errors: errors} = state
      ) do
    new_state =
      case Marketmailer.ESI.fetch(region_id, page) do
        {:ok, data, context} ->
          Marketmailer.Database.upsert_orders(data)
          Marketmailer.Database.upsert_etag(context.url, context.etag)

          notify_manager(manager, context.pages)
          schedule_next(context.ttl)
          %{state | errors: 0}

        {:not_modified, context} ->
          Marketmailer.Database.upsert_etag(context.url, context.etag)

          notify_manager(manager, context.pages)
          schedule_next(context.ttl)
          %{state | errors: 0}

        {:error, reason} ->
          delay = backoff_ms(errors)

          Logger.warning(
            "Fetch error for region #{region_id} page #{page}: #{inspect(reason)}; retry in #{div(delay, 1000)}s"
          )

          schedule_next(delay)
          %{state | errors: errors + 1}
      end

    {:noreply, new_state}
  end

  defp schedule_next(ttl_ms),
    do: Process.send_after(self(), :work, ttl_ms)

  defp notify_manager(manager, count),
    do: send(manager, {:update_page_count, count})

  # Exponential backoff capped at 5 minutes
  defp backoff_ms(errors) do
    base = 60_000
    max_delay = 5 * 60_000

    delay =
      base
      |> Kernel.*(:math.pow(2, errors))
      |> round()

    min(delay, max_delay)
  end
end

defmodule Marketmailer.ESI do
  require Logger

  @moduledoc false

  def fetch(region_id, page \\ 1) do
    url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"

    # Read ETag from DB-backed cache (optionally mirror to ETS)
    etag = Marketmailer.Database.get_etag(url)
    # Add the User-Agent to your headers list
    headers = [
      {"User-Agent", Marketmailer.Application.user_agent()}
    ]

    headers =
      if etag, do: [{"If-None-Match", etag} | headers], else: headers

    case Req.get(url, headers: headers, pool_timeout: :infinity) do
      {:ok, %{status: 200} = response} ->
        context = parse_metadata(response, url)

        Logger.info(
          "#{response.status} #{region_id} page #{page}\t#{length(response.body)} orders\t#{format_ttl(context.ttl)} #{url}"
        )

        {:ok, response.body, context}

      {:ok, %{status: 304} = response} ->
        context = parse_metadata(response, url)

        Logger.info(
          "#{response.status} #{region_id} page #{page}\t#{format_ttl(context.ttl)} #{url}"
        )

        {:not_modified, context}

      {:ok, response} ->
        Logger.warning("#{response.status} #{region_id} page #{page}\t#{url}")
        {:error, response.status}

      {:error, reason} ->
        Logger.error("HTTP error for region #{region_id} page #{page}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp header_first(headers, key),
    do: headers |> Map.get(key, []) |> List.first()

  defp parse_metadata(response, url) do
    raw_pages = header_first(response.headers, "x-pages")
    etag = header_first(response.headers, "etag")
    expires = header_first(response.headers, "expires")

    %{
      url: url,
      etag: etag,
      ttl: calculate_ttl(expires),
      pages: if(raw_pages, do: String.to_integer(raw_pages), else: 1)
    }
  end

  defp calculate_ttl(nil), do: 60_000

  defp calculate_ttl(expires) do
    with {{_, _, _}, {_, _, _}} = erl_dt <-
           :httpd_util.convert_request_date(String.to_charlist(expires)),
         datetime <- DateTime.from_naive!(NaiveDateTime.from_erl!(erl_dt), "Etc/UTC") do
      # at least 5 seconds, in ms
      max(DateTime.diff(datetime, DateTime.utc_now(), :millisecond), 5_000)
    else
      _ ->
        60_000
    end
  end

  defp format_ttl(ttl_ms) do
    total_seconds = div(ttl_ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    min = String.pad_leading("#{minutes}", 2, "0")
    sec = String.pad_leading("#{seconds}", 2, "0")

    "#{min}:#{sec}"
  end
end

defmodule Marketmailer.Database do
  use Ecto.Repo,
    otp_app: :marketmailer,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query

  @order_fields [
    :order_id,
    :duration,
    :is_buy_order,
    :issued,
    :location_id,
    :min_volume,
    :price,
    :range,
    :system_id,
    :type_id,
    :volume_remain,
    :volume_total,
    :inserted_at,
    :updated_at
  ]

  def upsert_orders([]), do: :ok

  def upsert_orders(orders) when is_list(orders) do
    timestamp = NaiveDateTime.utc_now(:second)

    rows =
      Enum.map(orders, fn order ->
        base =
          Enum.into(@order_fields, %{}, fn field ->
            key = Atom.to_string(field)
            {field, Map.get(order, key)}
          end)

        base
        |> Map.put(:inserted_at, timestamp)
        |> Map.put(:updated_at, timestamp)
      end)

    insert_all(
      Market,
      rows,
      on_conflict: {:replace, @order_fields},
      conflict_target: :order_id
    )
  end

  ## ETag helpers

  # For reads, optionally use ETS first for speed, then fall back to DB.
  def get_etag(url) do
    etag_from_ets =
      case :ets.lookup(:market_cache, url) do
        [{^url, etag}] -> etag
        _ -> nil
      end

    case etag_from_ets do
      nil ->
        case one(from e in Etag, where: e.url == ^url, select: e.etag) do
          nil ->
            nil

          etag ->
            :ets.insert(:market_cache, {url, etag})
            etag
        end

      etag ->
        etag
    end
  end

  # Single-row per URL, older rows effectively removed/overwritten.
  def upsert_etag(nil, _etag), do: :ok
  def upsert_etag(_url, nil), do: :ok

  def upsert_etag(url, etag) do
    now = NaiveDateTime.utc_now(:second)

    insert_all(
      Etag,
      [
        %{
          url: url,
          etag: etag,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:etag, :updated_at]},
      conflict_target: :url
    )

    # Keep ETS in sync as a write-through cache
    :ets.insert(:market_cache, {url, etag})
    :ok
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

  def changeset(etag, attrs) do
    etag
    |> cast(attrs, [:url, :etag])
    |> validate_required([:url, :etag])
    |> unique_constraint(:url)
  end
end

defmodule Marketmailer.EtagWarmup do
  use GenServer
  import Ecto.Query

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    send(self(), :warmup)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:warmup, state) do
    # Load all etags into ETS (if you expect millions, switch to streaming / limit)
    Marketmailer.Database.all(from e in Etag, select: {e.url, e.etag})
    |> Enum.each(fn {url, etag} ->
      :ets.insert(:market_cache, {url, etag})
    end)

    {:noreply, state}
  end
end
