CREATE INDEX IF NOT EXISTS idx_market_type_system_buy ON market (type_id, system_id, is_buy_order);
CREATE INDEX IF NOT EXISTS idx_market_price ON market (price);
ANALYZE market;

-- Speed up the Jita lookup
CREATE INDEX IF NOT EXISTS idx_market_jita_lookup 
ON market (type_id) 
WHERE (system_id = 30000142 AND is_buy_order = true);

-- Speed up the Remote Sell lookup
CREATE INDEX IF NOT EXISTS idx_market_remote_sells 
ON market (type_id, price) 
WHERE (is_buy_order = false);