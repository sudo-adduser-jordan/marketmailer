defmodule Marketmailer.Database do
  use Ecto.Repo,
    otp_app: :marketmailer,
    adapter: Ecto.Adapters.Postgres
end

defmodule Market do
  use Ecto.Schema

  # %{
  #   "duration" => 90,
  #   "is_buy_order" => true,
  #   "issued" => "2025-10-16T17:56:38Z",
  #   "location_id" => 1035466617946,
  #   "min_volume" => 1,
  #   "order_id" => 7163873707,
  #   "price" => 1001.0,
  #   "range" => "solarsystem",
  #   "system_id" => 30000240,
  #   "type_id" => 5339,
  #   "volume_remain" => 44,
  #   "volume_total" => 50
  # },

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


# create unique index(:markets, [:etag_url, :order_id])  # Prevent dupes
