defmodule Database.Migrations.Database do
	use Ecto.Migration

	# 	def create_market_view, do: :ok
	#     CREATE OR REPLACE VIEW "marketView" AS
	# SELECT
	#     m.order_id,
	#     m.issued,
	#     t."typeName" AS item_name,
	#     s."solarSystemName" AS system_name,
	#     st."stationName" AS location_name,
	#     m.price,
	#     m.volume_remain,
	#     m.volume_total,
	#     CASE
	#         WHEN m.is_buy_order = true THEN 'BUY'
	#         ELSE 'SELL'
	#     END AS order_type,
	#     m.duration,
	#     m.range,
	#     m.updated_at
	# FROM market m
	# LEFT JOIN "invTypes" t ON m.type_id = t."typeID"
	# LEFT JOIN "mapSolarSystems" s ON m.system_id = s."solarSystemID"
	# LEFT JOIN "staStations" st ON m.location_id = st."stationID";

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
			add :url, :string, primary_key: true
			add :etag, :string
			timestamps()
		end

		create table(:discord, primary_key: false) do
			add :guild_id, :bigint, primary_key: true
			add :channel_id, :bigint, null: false
			timestamps()
		end

		execute(fn ->
			dump_path = "/home/user1/Documents/GitHub/marketmailer/postgres-latest.dmp"

			host = System.get_env("PGHOST") || "127.0.0.1"
			port = System.get_env("PGPORT") || "5432"
			user = System.get_env("PGUSER") || "postgres"
			db = System.get_env("PGDATABASE") || "eve"
			pass = System.get_env("PGPASSWORD") || "postgres"

			command =
				"pg_restore --verbose --clean --no-acl --no-owner " <>
					"-h #{host} -p #{port} -U #{user} -d #{db} #{dump_path}"

			System.cmd("sh", ["-c", command],
				env: [
					{"PGPASSWORD", pass},
					{"PGHOST", host},
					{"PGPORT", port},
					{"PGUSER", user},
					{"PGDATABASE", db}
				]
			)

			IO.puts("Restore complete.")
		end)

		execute("""
		CREATE OR REPLACE VIEW "marketView" AS
		SELECT
		m.order_id,
		m.issued,
		t."typeName" AS item_name,
		s."solarSystemName" AS system_name,
		st."stationName" AS location_name,
		m.price,
		m.volume_remain,
		m.volume_total,
		CASE
		WHEN m.is_buy_order = true THEN 'BUY'
		ELSE 'SELL'
		END AS order_type,
		m.duration,
		m.range,
		m.updated_at
		FROM market m
		LEFT JOIN "invTypes" t ON m.type_id = t."typeID"
		LEFT JOIN "mapSolarSystems" s ON m.system_id = s."solarSystemID"
		LEFT JOIN "staStations" st ON m.location_id = st."stationID";
		""")
	end
end
