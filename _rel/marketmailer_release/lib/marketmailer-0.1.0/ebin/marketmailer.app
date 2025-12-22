{application, 'marketmailer', [
	{description, "New project"},
	{vsn, "0.1.0"},
	{modules, ['marketmailer_app','marketmailer_gen_server','marketmailer_http','marketmailer_sup']},
	{registered, [marketmailer_sup]},
	{applications, [kernel,stdlib,cowboy]},
	{optional_applications, []},
	{mod, {'marketmailer_app', []}},
	{env, []}
]}.