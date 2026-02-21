CREATE OR REPLACE VIEW "marketView" AS
SELECT 
    m.order_id,
    m.type_id,
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
