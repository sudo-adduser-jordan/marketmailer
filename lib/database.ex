defmodule Marketmailer.Database do
  use Ecto.Repo,
    otp_app: :marketmailer,
    adapter: Ecto.Adapters.Postgres
end

defmodule Database.Market do
  use Ecto.Schema

  schema "market" do
    field :duration,        :integer
    field :is_buy_order,    :integer
    field :issued,          :integer
    field :location_id,     :integer
    field :min_volume,      :integer
    field :order_id,        :integer
    field :price,           :integer
    field :range,           :integer
    field :system_id,       :integer
    field :type_id,         :integer
    field :volume_remain,   :integer
    field :volume_total,    :integer
  end
end
