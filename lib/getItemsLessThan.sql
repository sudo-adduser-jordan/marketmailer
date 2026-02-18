SELECT s.*, (b."price" - s."price") AS margin
FROM public."marketView" s
JOIN public."marketView" b
  ON s."item_name" = b."item_name"
  AND s."system_name" != 'Jita'
  AND b."system_name" = 'Jita'
  AND s."order_type" = 'SELL'
  AND b."order_type" = 'BUY'
WHERE s."price" < b."price"
ORDER BY margin DESC;