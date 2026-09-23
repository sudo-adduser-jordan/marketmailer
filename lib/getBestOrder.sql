-- Best remote sell order that can be instantly flipped into the Jita buy wall.
-- 30000142 is the Jita solarSystemID.
WITH JitaBestBuy AS (
    -- Absolute best buy price for every item in Jita
    SELECT 
        type_id, 
        MAX(price) AS jita_buy_price,
        SUM(volume_remain) AS jita_total_demand
    FROM market
    WHERE system_id = 30000142 
      AND is_buy_order = 1
    GROUP BY type_id
)
SELECT 
    m.order_id,
    m.issued,
    m.type_id,
    tn.name AS item_name,
    sy.region_name,
    sy.name AS system_name,
    sy.security_status,
    ln.name AS location_name,
    m.system_id,
    m.location_id,
    m.price,
    m.volume_remain,
    m.volume_total,
    m.min_volume,
    'SELL' AS order_type,
    m.duration,
    m."range",
    ((jb.jita_buy_price - m.price) * MIN(COALESCE(m.volume_remain, 0), COALESCE(jb.jita_total_demand, 0))) AS instant_sell_profit
FROM market m
JOIN JitaBestBuy jb ON m.type_id = jb.type_id
LEFT JOIN names tn ON tn.id = m.type_id
LEFT JOIN names ln ON ln.id = m.location_id
LEFT JOIN systems sy ON sy.system_id = m.system_id
WHERE m.is_buy_order = 0 
  AND sy.name IS NOT 'Jita'
  AND m.price < jb.jita_buy_price
ORDER BY instant_sell_profit DESC
LIMIT 1;
