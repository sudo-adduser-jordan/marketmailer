WITH jita_bids AS (
    SELECT m.type_id, m.price, m.volume_remain,
        SUM(m.volume_remain) OVER (
            PARTITION BY m.type_id ORDER BY m.price DESC, m.order_id
            ROWS UNBOUNDED PRECEDING
        ) AS cum_vol
    FROM market m
    WHERE m.system_id = 30000142 AND m.is_buy_order = 1
),
jita_sell AS (
    SELECT m.type_id, MIN(m.price) AS price
    FROM market m
    WHERE m.system_id = 30000142 AND m.is_buy_order = 0
    GROUP BY m.type_id
),
capital_avg AS (
    SELECT m.type_id, AVG(m.price) AS price
    FROM market m
    JOIN names n ON n.id = m.type_id
    WHERE m.is_buy_order = 0 AND COALESCE(n.is_capital_ship, 0) = 1
    GROUP BY m.type_id
),
fill_per_row AS (
    SELECT
        i.contract_id,
        i.record_id,
        COALESCE(SUM(
            MAX(0, MIN(b.cum_vol, COALESCE(i.quantity, 0)) - MAX(b.cum_vol - b.volume_remain, 0)) * b.price
        ), 0) AS fill_value
    FROM contract_items i
    JOIN names n ON n.id = i.type_id
    JOIN jita_bids b ON b.type_id = i.type_id
    WHERE i.is_included = 1 AND COALESCE(i.is_blueprint_copy, 0) = 0
        AND COALESCE(n.is_capital_ship, 0) = 0
    GROUP BY i.contract_id, i.record_id
),
capital_fill AS (
    SELECT
        i.contract_id,
        i.record_id,
        COALESCE(i.quantity, 0) * COALESCE(ca.price, 0) AS fill_value
    FROM contract_items i
    JOIN names n ON n.id = i.type_id AND COALESCE(n.is_capital_ship, 0) = 1
    LEFT JOIN capital_avg ca ON ca.type_id = i.type_id
    WHERE i.is_included = 1 AND COALESCE(i.is_blueprint_copy, 0) = 0
),
included_sums AS (
    SELECT contract_id, COALESCE(SUM(fill_value), 0) AS gross_value
    FROM (
        SELECT contract_id, fill_value FROM fill_per_row
        UNION ALL
        SELECT contract_id, fill_value FROM capital_fill
    )
    GROUP BY contract_id
),
included_counts AS (
    SELECT i.contract_id, COUNT(*) AS item_count
    FROM contract_items i
    WHERE i.is_included = 1 AND COALESCE(i.is_blueprint_copy, 0) = 0
    GROUP BY i.contract_id
),
requested_sums AS (
    SELECT
        i.contract_id,
        COALESCE(SUM(COALESCE(i.quantity, 0) * COALESCE(s.price, 0)), 0) AS requested_cost
    FROM contract_items i
    LEFT JOIN jita_sell s ON s.type_id = i.type_id
    WHERE i.is_included = 0 AND COALESCE(i.is_blueprint_copy, 0) = 0
    GROUP BY i.contract_id
),
capital_flag AS (
    SELECT i.contract_id, MAX(COALESCE(n.is_capital_ship, 0)) AS has_capital
    FROM contract_items i
    LEFT JOIN names n ON n.id = i.type_id
    WHERE i.is_included = 1 AND COALESCE(i.is_blueprint_copy, 0) = 0
    GROUP BY i.contract_id
),
contract_values AS (
    SELECT
        a.contract_id,
        COALESCE(g.gross_value, 0) AS items_value,
        COALESCE(r.requested_cost, 0) AS requested_cost,
        COALESCE(f.has_capital, 0) AS has_capital,
        COALESCE(c.item_count, 0) AS item_count
    FROM (
        SELECT contract_id FROM included_counts
        UNION
        SELECT contract_id FROM included_sums
        UNION
        SELECT contract_id FROM requested_sums
        UNION
        SELECT contract_id FROM capital_flag
    ) a
    LEFT JOIN included_sums g ON g.contract_id = a.contract_id
    LEFT JOIN included_counts c ON c.contract_id = a.contract_id
    LEFT JOIN requested_sums r ON r.contract_id = a.contract_id
    LEFT JOIN capital_flag f ON f.contract_id = a.contract_id
)
SELECT
    c.contract_id,
    c.region_id,
    c.type,
    c.title,
    c.price,
    c.buyout,
    v.items_value,
    (v.items_value - v.requested_cost - COALESCE(c.price, c.buyout, 0)) AS margin,
    v.item_count,
    v.has_capital,
    c.expires_at,
    c.start_location_id,
    COALESCE(ln.name, sy.name,
        CASE WHEN c.start_location_id >= 1000000000000 THEN 'Player Station' ELSE '?' END) AS location_name,
    COALESCE(r.name, '?') AS region_name
FROM contracts c
JOIN contract_values v ON v.contract_id = c.contract_id
LEFT JOIN names ln ON ln.id = c.start_location_id
LEFT JOIN systems sy ON sy.system_id = c.start_location_id
LEFT JOIN regions r ON r.region_id = c.region_id
WHERE c.last_seen_round = ?
    AND c.expires_at > ?
    AND c.items_fetched = 1
    AND (v.items_value - v.requested_cost - COALESCE(c.price, c.buyout, 0)) >= ?
ORDER BY margin DESC, c.contract_id ASC
LIMIT ?;
