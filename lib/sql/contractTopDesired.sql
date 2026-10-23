WITH jita_buy AS (
    SELECT m.type_id, MAX(m.price) AS price
    FROM market m
    WHERE m.system_id = 30000142 AND m.is_buy_order = 1
    GROUP BY m.type_id
),
capital_avg AS (
    SELECT m.type_id, AVG(m.price) AS price
    FROM market m
    JOIN names n ON n.id = m.type_id
    WHERE m.is_buy_order = 0 AND COALESCE(n.is_capital_ship, 0) = 1
    GROUP BY m.type_id
),
contract_values AS (
    SELECT
        i.contract_id,
        SUM(
            i.quantity * CASE
                WHEN COALESCE(n.is_capital_ship, 0) = 1
                    THEN COALESCE(ca.price, 0)
                ELSE COALESCE(jb.price, 0)
            END
        ) AS items_value,
        COUNT(*) AS item_count,
        MAX(COALESCE(n.is_capital_ship, 0)) AS has_capital
    FROM contract_items i
    LEFT JOIN names n ON n.id = i.type_id
    LEFT JOIN jita_buy jb ON jb.type_id = i.type_id
    LEFT JOIN capital_avg ca ON ca.type_id = i.type_id
    WHERE i.is_included = 1 AND COALESCE(i.is_blueprint_copy, 0) = 0
    GROUP BY i.contract_id
)
SELECT
    c.contract_id,
    c.region_id,
    c.type,
    c.title,
    c.price,
    c.buyout,
    v.items_value,
    (v.items_value - COALESCE(c.price, c.buyout, 0)) AS margin,
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
    AND (v.items_value - COALESCE(c.price, c.buyout, 0)) >= ?
ORDER BY margin DESC, c.contract_id ASC
LIMIT ?;
