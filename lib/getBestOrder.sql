WITH JitaBestBuy AS (
    -- Get the absolute best buy price for every item in Jita
    -- 30000142 is the Jita solarSystemID
    SELECT 
        type_id, 
        MAX(price) AS jita_buy_price,
        SUM(volume_remain) AS jita_total_demand
    FROM market
    WHERE system_id = 30000142 
      AND is_buy_order = true
    GROUP BY type_id
)
SELECT 
    v.order_id,
    v.issued,
    v.type_id,
    v.item_name,
    v.system_name,
    v.location_name,
    v.price,
    v.volume_remain,
    v.volume_total,
    v.order_type,
    v.duration,
    v.range,
    v.updated_at,
    -- Profit metrics added to the end
    -- (jb.jita_buy_price - v.price) AS profit_per_unit,
    ((jb.jita_buy_price - v.price) * LEAST(v.volume_remain, jb.jita_total_demand)) AS instant_sell_profit
FROM "marketView" v
JOIN JitaBestBuy jb ON v.type_id = jb.type_id
WHERE v.order_type = 'SELL' 
  AND v.system_name != 'Jita'
  AND v.price < jb.jita_buy_price
ORDER BY instant_sell_profit DESC
LIMIT 1;
-- LIMIT 99;