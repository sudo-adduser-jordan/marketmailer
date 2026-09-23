# Used by "mix format"
[
	import_deps: [:ecto, :ecto_sql, :ecto_sqlite3],
	inputs: ["{mix,.formatter}.exs", "{config,lib,test,priv}/**/*.{ex,exs}"],
	line_length: 120,
	plugins: [Quokka, HendricksFormatter]
]
