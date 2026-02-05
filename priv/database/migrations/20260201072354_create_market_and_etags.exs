
defmodule Marketmailer.Database.Migrations.CreateMarketAndEtags do
  use Ecto.Migration

  def change do
    create table(:market, primary_key: false) do
      add :order_id, :bigint, primary_key: true
      add :duration, :integer
      add :is_buy_order, :boolean
      add :issued, :string
      add :location_id, :bigint
      add :min_volume, :integer
      add :price, :float
      add :range, :string
      add :system_id, :integer
      add :type_id, :integer
      add :volume_remain, :integer
      add :volume_total, :integer
      timestamps()
    end

    create table(:etags, primary_key: false) do
      add :etag, :string, primary_key: true
      add :url, :string
    end

  end
end
