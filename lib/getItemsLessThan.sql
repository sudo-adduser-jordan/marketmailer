-- Top remote sell orders from the reusable market undercutting view.
SELECT *
FROM marketListView
ORDER BY margin DESC
LIMIT 100;
