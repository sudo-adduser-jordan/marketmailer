defmodule Marketmailer.Database.Migrations.CreateMarket do
  use Ecto.Migration

  def change do
    create table(:market) do
    add :duration, :integer
    add :is_buy_order, :boolean
    add :issued, :string
    add :location_id, :bigint
    add :min_volume, :integer
    add :order_id, :bigint
    add :price, :float
    add :range, :string
    add :system_id, :integer
    add :type_id, :integer
    add :volume_remain, :integer
    add :volume_total, :integer
  end

  end
end
