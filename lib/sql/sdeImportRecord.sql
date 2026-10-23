INSERT INTO sde_imports (build, imported_at) VALUES (?, ?)
ON CONFLICT(build) DO UPDATE SET imported_at = excluded.imported_at;
