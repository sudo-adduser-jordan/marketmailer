import Config

config :logger, :console,
	format: "$message\n",
	metadata: []

config :marketmailer, Database,
	username: "postgres",
	password: "postgres",
	database: "eve",
	hostname: "localhost",
	# instead of making a queue in gen server, configure postgres to not timeout requests in its queue
	queue_interval: System.schedulers_online() * 10000,
	timeout: System.schedulers_online() * 10000,
	# pool_size: System.schedulers_online() * 4,
	log: false

config :marketmailer, Marketmailer.Mailer,
	adapter: Swoosh.Adapters.Resend,
	api_key: System.get_env("RESEND_TOKEN")

config :marketmailer, ecto_repos: [Database]
