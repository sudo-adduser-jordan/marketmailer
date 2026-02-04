defmodule Marketmailer.Database do
  use Ecto.Repo,
    otp_app: :marketmailer,
    adapter: Ecto.Adapters.Postgres

  @order_fields [
    :order_id, :duration, :is_buy_order, :issued, :location_id,
    :min_volume, :price, :range, :system_id, :type_id,
    :volume_remain, :volume_total
  ]

  def upsert_orders(orders) do

    entries = Enum.map(orders, fn order ->
      Map.new(@order_fields, fn field ->
        {field, Map.get(order, Atom.to_string(field))}
      end)
    end)

    insert_all(
      Market,
      entries,
        on_conflict: {:replace, @order_fields},
        conflict_target: :order_id
    )
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
  end
end


defmodule Etag do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:url, :string, autogenerate: false}
  schema "etags" do
    field :etag, :string
    timestamps()
  end

  def changeset(etag, attrs) do
    etag
    |> cast(attrs, [:url, :etag])
    |> validate_required([:url, :etag])
    |> unique_constraint(:url)
  end
end


defmodule Marketmailer.Database.Migrations.CreateMarketAndEtags do
  use Ecto.Migration

  def change do

    create table(:market, primary_key: false) do
      add :order_id, :bigint, primary_key: true
      add :duration, :integer
      add :is_buy_order, :boolean
      add :issued, :string
      # add :issued, :utc_datetime # Changed to datetime for better querying
      add :location_id, :bigint
      add :min_volume, :integer
      add :price, :float
      add :range, :string
      add :system_id, :integer
      add :type_id, :integer
      add :volume_remain, :integer
      add :volume_total, :integer
    end

    create table(:etags, primary_key: false) do
      add :url, :string, primary_key: true
      add :etag, :string
    end


    # create unique_index(:market, [:etag_url, :order_id]) # Prevent dupes
  end
end
