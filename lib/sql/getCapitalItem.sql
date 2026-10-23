SELECT
    tn.id AS type_id,
    tn.name AS item_name
FROM names tn
WHERE tn.is_capital_ship = 1
  AND LOWER(TRIM(tn.name)) = ?
LIMIT 1;
