# defmodule Database.Migrations.Database do
# 	use Ecto.Migration

# 	def change do
# 		create table(:market, primary_key: false) do
# 			add :order_id, :bigint, primary_key: true
# 			add :duration, :integer
# 			add :is_buy_order, :boolean
# 			add :issued, :string
# 			add :location_id, :bigint
# 			add :min_volume, :integer
# 			add :price, :float
# 			add :range, :string
# 			add :system_id, :integer
# 			add :type_id, :integer
# 			add :volume_remain, :integer
# 			add :volume_total, :integer
# 			timestamps()
# 		end

# 		create table(:etags, primary_key: false) do
# 			add :url, :string, primary_key: true
# 			add :etag, :string
# 			timestamps()
# 		end

# 		create table(:discord, primary_key: false) do
# 			add :guild_id, :bigint, primary_key: true
# 			add :channel_id, :bigint, null: false
# 			timestamps()
# 		end

# 		execute(fn ->
# 			dump_path = "/home/user1/Documents/GitHub/marketmailer/postgres-latest.dmp"

# 			host = System.get_env("PGHOST") || "127.0.0.1"
# 			port = System.get_env("PGPORT") || "5432"
# 			user = System.get_env("PGUSER") || "postgres"
# 			db = System.get_env("PGDATABASE") || "eve"
# 			pass = System.get_env("PGPASSWORD") || "postgres"

# 			command =
# 				"pg_restore --verbose --clean --no-acl --no-owner " <>
# 					"-h #{host} -p #{port} -U #{user} -d #{db} #{dump_path}"

# 			System.cmd("sh", ["-c", command],
# 				env: [
# 					{"PGPASSWORD", pass},
# 					{"PGHOST", host},
# 					{"PGPORT", port},
# 					{"PGUSER", user},
# 					{"PGDATABASE", db}
# 				]
# 			)

# 			IO.puts("Restore complete.")
# 		end)
# 	end
# end
