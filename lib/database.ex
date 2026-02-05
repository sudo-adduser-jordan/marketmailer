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
