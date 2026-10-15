defmodule Database.Migrations.Schema do
	use Ecto.Migration

	# Squashed init (replaces 20260822..20261016): the full end-state schema
	# in one migration. Table creation is guarded by sqlite_master lookups
	# and indexes/view cleanup use IF NOT EXISTS / DROP IF EXISTS, so it
	# safely no-ops on databases that already ran the old chain and fully
	# builds fresh ones. Name data itself comes only from `mix sde.import`,
	# never from seeds here.
	def up do
		unless table_exists?("market") do
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

			create index(:market, [:type_id],
				where: "system_id = 30000142 AND is_buy_order = 1"
			)

			create index(:market, [:type_id, :price], where: "is_buy_order = 0")
			create index(:market, [:updated_at, :order_id])
		end

		unless table_exists?("etags") do
			create table(:etags, primary_key: false) do
				add :url, :string, primary_key: true
				add :etag, :string
				add :expires_at, :bigint
				timestamps()
			end
		end

		unless table_exists?("discord") do
			create table(:discord, primary_key: false) do
				add :guild_id, :bigint, primary_key: true
				add :channel_id, :bigint, null: false
				timestamps()
			end
		end

		unless table_exists?("names") do
			create table(:names, primary_key: false) do
				add :id, :integer, primary_key: true
				add :name, :string, null: false
			end

			# Prefix search for check_market autocomplete over a ~17k-row names table.
			create index(:names, [:name])
		end

		unless table_exists?("systems") do
			create table(:systems, primary_key: false) do
				add :system_id, :integer, primary_key: true
				add :name, :string, null: false
				add :security_status, :float
				add :region_name, :string, null: false
			end
		end

		# Leftover from the removed write -> read copy layer; drop it where
		# it exists (single-DB mode has no watermark).
		execute("DROP TABLE IF EXISTS _sync_watermark")

		execute("DROP VIEW IF EXISTS marketListView")

		# Player-owned structures are dynamic and never in the SDE:
		# unmatched 64-bit location ids (>= 10^12) render as
		# "Player Station", anything else unmatched stays "?" to signal an
		# SDE import gap.
		execute("""
		CREATE VIEW marketListView AS
		WITH JitaBuy AS (
				SELECT
						type_id,
						MAX(price) AS buy_price
				FROM market
				WHERE system_id = 30000142
					AND is_buy_order = 1
				GROUP BY type_id
		)
		SELECT
				tn.name AS item,
				jb.buy_price AS buy_price,
				s.price AS sell_price,
				(jb.buy_price - s.price) AS margin,
				s.order_id,
				s.type_id,
				s.system_id,
				s.location_id,
				s.volume_remain,
				s.volume_total,
				s.issued,
				s.duration,
				s."range",
				sy.name AS system_name,
				sy.security_status,
				sy.region_name,
				COALESCE(ln.name,
					CASE WHEN s.location_id >= 1000000000000 THEN 'Player Station' ELSE '?' END) AS location_name
		FROM market s
		JOIN JitaBuy jb ON jb.type_id = s.type_id
		LEFT JOIN names tn ON tn.id = s.type_id
		LEFT JOIN names ln ON ln.id = s.location_id
		LEFT JOIN systems sy ON sy.system_id = s.system_id
		WHERE s.is_buy_order = 0
			AND s.price < jb.buy_price
		""")
	end
	defp table_exists?(table) do
		%{rows: [[count]]} =
			repo().query!("SELECT COUNT\(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [table])

		count > 0
	end


	defp table_exists?(table) do
		%{rows: [[count]]} =
			repo().query!("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [table])

		count > 0
	end

	def down do
		execute("DROP VIEW IF EXISTS marketListView")
		drop_if_exists(table(:market))
		drop_if_exists(table(:etags))
		drop_if_exists(table(:discord))
		drop_if_exists(table(:names))
		drop_if_exists(table(:systems))
	end
end
