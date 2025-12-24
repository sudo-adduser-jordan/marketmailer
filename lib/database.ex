defmodule Marketmailer.Database do
  use Ecto.Repo,
    otp_app: :marketmailer,
    adapter: Ecto.Adapters.Postgres
end

defmodule Market do
  use Ecto.Schema

  schema "market" do
    field :city,    :string
    field :temp_lo, :integer
    field :temp_hi, :integer
    field :prcp,    :float, default: 0.0
  end
end
