SELECT sql
FROM sqlite_master
WHERE type = 'index' AND tbl_name = 'market' AND name NOT LIKE 'sqlite_autoindex%';
