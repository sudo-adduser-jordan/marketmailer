defmodule Database.Migrations.FilterCapitalShips do
	use Ecto.Migration

	def up do
		alter table(:names) do
			add :is_capital_ship, :boolean, null: false, default: false
		end

		create_view("AND COALESCE(tn.is_capital_ship, 0) = 0")
	end

	def down do
		create_view("")

		alter table(:names) do
			remove :is_capital_ship
		end
	end

	defp create_view(capital_filter) do
		execute("DROP VIEW IF EXISTS marketListView")

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
			#{capital_filter}
		""")
	end
end
