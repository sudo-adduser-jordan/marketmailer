-- Item-name completions for check_market autocomplete: distinct names with
-- a cached Jita 4-4 (station 60003760) sell order, prefix matches first.
SELECT DISTINCT
    tn.id AS type_id,
    tn.name AS item_name
FROM names tn
JOIN market m ON m.type_id = tn.id
WHERE m.is_buy_order = 0
  AND m.location_id = 60003760
  AND LOWER(tn.name) LIKE ? ESCAPE '\'
ORDER BY
  CASE WHEN LOWER(tn.name) LIKE ? ESCAPE '\' THEN 0 ELSE 1 END,
  LENGTH(tn.name) ASC,
  tn.name ASC
LIMIT ?;
