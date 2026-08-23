defmodule Database.Migrations.Init do
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

		# Jita lookup + remote sell scans (30000142 = Jita)
		create index(:market, [:type_id, :system_id, :is_buy_order])
		create index(:market, [:price])
		create index(:market, [:type_id], where: "system_id = 30000142 AND is_buy_order = 1")
		create index(:market, [:type_id, :price], where: "is_buy_order = 0")

		create table(:etags, primary_key: false) do
			add :url, :string, primary_key: true
			add :etag, :string
			timestamps()
		end

		create table(:discord, primary_key: false) do
			add :guild_id, :bigint, primary_key: true
			add :channel_id, :bigint, null: false
			timestamps()
		end

		# lazy EVE name caches (see lib/names.ex)
		create table(:names, primary_key: false) do
			add :id, :integer, primary_key: true
			add :name, :string, null: false
		end

		create table(:systems, primary_key: false) do
			add :system_id, :integer, primary_key: true
			add :name, :string, null: false
			add :security_status, :float
			add :region_name, :string, null: false
		end
	end
end
