defmodule Database.Migrations.Schema do
	use Ecto.Migration

	# Squashed init (replaces 20261017000000..20261027000000): the full schema
	# in one migration and the only migration the project has. It assumes an
	# empty database and creates every table, index and view directly; there
	# are no compatibility guards and no data repairs, so an existing database
	# from the old chain must be discarded (its data is derived cache).
	#
	# Name data itself comes only from `mix sde.import`, never from seeds here.
	def up do
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
			add :url, :string
			timestamps()
		end

		create index(:market, [:type_id, :system_id, :is_buy_order])
		create index(:market, [:price])

		# Jita buy wall (30000142) and remote sell scans
		create index(:market, [:type_id], where: "system_id = 30000142 AND is_buy_order = 1")
		create index(:market, [:type_id, :price], where: "is_buy_order = 0")
		create index(:market, [:updated_at, :order_id])
		create index(:market, [:location_id, :is_buy_order, :type_id])

		create index(:market, [:type_id, :price, :volume_remain], where: "system_id = 30000142 AND is_buy_order = 1")

		# Per-page stale sweep deletes by the fetched page url.
		create index(:market, [:url])

		create table(:etags, primary_key: false) do
			add :url, :string, primary_key: true
			add :etag, :string
			add :expires_at, :bigint
			timestamps()
		end

		create table(:discord, primary_key: false) do
			add :guild_id, :bigint, primary_key: true
			add :channel_id, :bigint, null: false
			timestamps()
		end

		# Published SDE types plus composed NPC station names. Capital hulls
		# that cannot enter high sec are flagged by `mix sde.import` so every
		# Jita buy-wall query can filter them out.
		create table(:names, primary_key: false) do
			add :id, :integer, primary_key: true
			add :name, :string, null: false
			add :is_capital_ship, :boolean, null: false, default: false
		end

		create index(:names, [:name])

		create table(:systems, primary_key: false) do
			add :system_id, :integer, primary_key: true
			add :name, :string, null: false
			add :security_status, :float
			add :region_name, :string, null: false
		end

		# SDE region cache: the poller list is derived from mapRegions.jsonl
		# instead of a hardcoded id range, so a missing region (e.g. Exordium
		# 10001004) can never be silently skipped again.
		create table(:regions, primary_key: false) do
			add :region_id, :integer, primary_key: true
			add :name, :string, null: false
		end

		create table(:contracts, primary_key: false) do
			add :contract_id, :bigint, primary_key: true
			add :region_id, :integer, null: false
			add :page, :integer, null: false
			add :type, :string
			add :title, :string
			add :price, :float
			add :buyout, :float
			add :reward, :float
			add :collateral, :float
			add :volume, :float
			add :expires_at, :bigint
			add :issued_at, :bigint
			add :days_to_complete, :integer
			add :start_location_id, :bigint
			add :end_location_id, :bigint
			add :issuer_id, :bigint
			add :issuer_corporation_id, :bigint
			add :items_fetched, :boolean, null: false, default: false
			add :items_attempts, :integer, null: false, default: 0
			add :items_next_attempt_at, :bigint, null: false, default: 0
			add :items_claim_round, :integer, null: false, default: 0
			add :last_seen_round, :integer, null: false, default: 0
			timestamps()
		end

		create index(:contracts, [:region_id, :page])
		create index(:contracts, [:items_fetched, :items_next_attempt_at, :expires_at])
		create index(:contracts, [:last_seen_round, :expires_at])
		create index(:contracts, [:price])

		create table(:contract_items, primary_key: false) do
			add :record_id, :bigint, primary_key: true
			add :contract_id, :bigint, primary_key: true
			add :type_id, :integer, null: false
			add :quantity, :integer
			add :is_included, :boolean
			add :is_blueprint_copy, :boolean
		end

		create index(:contract_items, [:contract_id])
		create index(:contract_items, [:type_id])

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
			AND COALESCE(tn.is_capital_ship, 0) = 0
		""")
	end

	def down do
		execute("DROP VIEW IF EXISTS marketListView")
		drop table(:contract_items)
		drop table(:contracts)
		drop table(:regions)
		drop table(:systems)
		drop table(:names)
		drop table(:discord)
		drop table(:etags)
		drop table(:market)
	end
end
