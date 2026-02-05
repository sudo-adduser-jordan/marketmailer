defmodule Marketmailer.Application do
  use Application

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

  def start(_type, _args) do
    :ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])

    region_manager_specs = Enum.map(@regions, fn region_id ->
      Supervisor.child_spec({Marketmailer.RegionManager, region_id}, id: {:region_manager, region_id})
    end)

    children = [
      Marketmailer.Database,
      {Registry, keys: :unique, name: Marketmailer.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
      {Task.Supervisor, name: Marketmailer.TaskSup},

      %{
        id: Marketmailer.RegionManagerSupervisor,
        start: {Supervisor, :start_link, [region_manager_specs, [strategy: :one_for_one]]}
      }
    ]

    opts = [strategy: :one_for_one, name: Marketmailer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule Marketmailer.RegionManager do
  use GenServer

  def start_link(region_id),
    do: GenServer.start_link(__MODULE__, region_id, name: via(region_id))

  defp via(id), do: {:via, Registry, {Marketmailer.Registry, {:region, id}}}

  def init(id) do
    # Start page 1 immediately
    DynamicSupervisor.start_child(Marketmailer.PageSup, {Marketmailer.PageWorker, {id, 1}})
    # At least page 1 exists
    {:ok, %{id: id, page_count: 1}}
  end

  def handle_info({:update_page_count, new_count}, %{id: id, page_count: current} = state) do
    if new_count != current do
      adjust_workers(id, current, new_count)
      {:noreply, %{state | page_count: new_count}}
    else
      {:noreply, state}
    end
  end

  defp adjust_workers(id, old, new) when new > old do
    Enum.each((old + 1)..new, fn p ->
      DynamicSupervisor.start_child(Marketmailer.PageSup, {Marketmailer.PageWorker, {id, p}})
    end)
  end

  defp adjust_workers(id, old, new) when new < old do
    Enum.each((new + 1)..old, fn p ->
      # Gracefully stop workers that are no longer needed
      case Registry.lookup(Marketmailer.Registry, {:page, id, p}) do
        [{pid, _}] -> GenServer.stop(pid)
        _ -> :ok
      end
    end)
  end
end

defmodule Marketmailer.PageWorker do
  use GenServer, restart: :transient

  def start_link({region_id, page}),
    do: GenServer.start_link(__MODULE__, {region_id, page}, name: via(region_id, page))

  defp via(region_id, page),
    do: {:via, Registry, {Marketmailer.Registry, {:page, region_id, page}}}

  def init({region_id, page}) do
    send(self(), :work)
    {:ok, {region_id, page}}
  end

  def handle_info(:work, {region_id, page} = state) do
    case Marketmailer.ESI.fetch(region_id, page) do
      {:ok, data, context} ->

        Marketmailer.Database.upsert_orders(data)
        :ets.insert(:market_cache, {context.url, context.etag})

        notify_manager(region_id, context.pages)
        schedule_next(context.ttl)

      {:not_modified, context} ->
        notify_manager(region_id, context.pages)
        schedule_next(context.ttl)

      {:error, _} ->
        IO.puts("fetch error")
        schedule_next(60_000)
    end

    {:noreply, state}
  end

  defp schedule_next(ttl), do: Process.send_after(self(), :work, ttl)

  defp notify_manager(region_id, count) do
    case Registry.lookup(Marketmailer.Registry, {:region, region_id}) do
      [{pid, _}] -> send(pid, {:update_page_count, count})
      _ -> :ok
    end
  end
end

defmodule Marketmailer.ESI do
  require Logger

  def fetch(region_id, page \\ 1) do
    url = "https://esi.evetech.net/v1/markets/#{region_id}/orders/?page=#{page}"

    etag =
      case :ets.lookup(:market_cache, url) do
        [{_, val}] -> val
        _ -> nil
      end

    headers = if etag, do: [{"if-none-match", etag}], else: []


    # handle 503, handle 404 halt and only ping for status
    case Req.get(url, headers: headers, pool_timeout: :infinity) do
      {:ok, %{status: 200} = response} ->
        new_etag = response.headers["etag"] |> List.first()
        if new_etag, do: :ets.insert(:market_cache, {url, new_etag})

        context = parse_metadata(response, url)

        Logger.info(
          "#{response.status} #{region_id} page #{page} \t #{length(response.body)} orders  \t #{format_ttl(context.ttl)} #{url}"
        )

        {:ok, response.body, context}

      {:ok, %{status: 304} = response} ->
        context = parse_metadata(response, url)
        Logger.info("#{response.status} #{region_id} page #{page} \t #{format_ttl(context.ttl)} #{url}")
        {:not_modified, context}

      {:ok, response} ->
        Logger.info("#{response.status} #{region_id} page #{page} \t #{url}")
        {:error, response.status}

      {:error, reason} ->
        Logger.info("Error: #{reason}")

        {:error, reason}
    end
  end

  defp parse_metadata(response, url) do
    raw_pages = response.headers["x-pages"] |> List.first()
    %{
      url: url,
      etag: response.headers["etag"] |> List.first(),
      ttl: calculate_ttl(response.headers["expires"] |> List.first()),
      pages: if(raw_pages, do: String.to_integer(raw_pages), else: 1)
    }
  end

  defp calculate_ttl(nil) do
    60_000
  end

  defp calculate_ttl(expires) do
    with {{_, _, _}, {_, _, _}} = erl_dt <-
           :httpd_util.convert_request_date(String.to_charlist(expires)),
         datetime <- DateTime.from_naive!(NaiveDateTime.from_erl!(erl_dt), "Etc/UTC") do
      max(DateTime.diff(datetime, DateTime.utc_now(), :millisecond), 5000)
    else
      _ ->
        60000
    end
  end

  defp format_ttl(ttl_ms) do
    total_seconds = div(ttl_ms, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    # Using string interpolation and padding
    m = String.pad_leading("#{minutes}", 2, "0")
    s = String.pad_leading("#{seconds}", 2, "0")

    "#{m}:#{s}"
  end

end

defmodule Marketmailer.Database do
  use Ecto.Repo, otp_app: :marketmailer, adapter: Ecto.Adapters.Postgres

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

  def upsert_orders(orders) when is_list(orders) do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    entries =
      Enum.map(orders, fn order ->
        Map.new(@order_fields, fn field ->
          {field, Map.get(order, Atom.to_string(field))}
        end)
        |> Map.put(:inserted_at, timestamp)
        |> Map.put(:updated_at, timestamp)
      end)

    insert_all(
      Market,
      entries,
      on_conflict: {:replace, @order_fields},
      conflict_target: :order_id
    )
  end
end

# Marketmailer.Database.
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
  end

  def changeset(etag, attrs) do
    etag
    |> cast(attrs, [:url, :etag])
    |> validate_required([:url, :etag])
    |> unique_constraint(:url)
  end
end
