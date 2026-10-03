# Used by "mix format"
[
	import_deps: [:ecto, :ecto_sql, :ecto_sqlite3, :phoenix, :phoenix_live_view, :phoenix_live_dashboard],
	inputs: ["{mix,.formatter}.exs", "{config,lib,test,priv}/**/*.{ex,exs}"],
	line_length: 120,
	plugins: [Quokka, HendricksFormatter]
]
