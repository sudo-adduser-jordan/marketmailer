import Config

config :logger, :console,
	format: "$message\n",
	metadata: []

config :marketmailer, ecto_repos: [Marketmailer.Database]

config :marketmailer, Marketmailer.Database,
	username: "postgres",
	password: "postgres",
	database: "eve",
	hostname: "localhost",
	# instead of making a queue in gen server, configure postgres to not timeout requests in its queue
	queue_interval: System.schedulers_online() * 1000,
	timeout: System.schedulers_online() * 1000,
	# pool_size: System.schedulers_online() * 4,
	log: false


config :marketmailer, Marketmailer.Mailer,
	adapter: Swoosh.Adapters.Resend,
	api_key: System.get_env("RESEND_TOKEN")
