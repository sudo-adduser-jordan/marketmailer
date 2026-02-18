defmodule Discord do
	use Ecto.Schema

	@primary_key {:guild_id, :integer, autogenerate: false}

	schema "discord" do
		field :channel_id, :integer
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

defmodule Market do
	use Ecto.Schema

	@primary_key false
	schema "market" do
		field :order_id, :id, primary_key: true
		field :duration, :integer
		field :is_buy_order, :boolean
		field :issued, :string
		field :location_id, :integer
		field :min_volume, :integer
		field :price, :float
		field :range, :string
		field :system_id, :integer
		field :type_id, :integer
		field :volume_remain, :integer
		field :volume_total, :integer
		timestamps()
	end
end
