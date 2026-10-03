import Config

# Isolated dev-test env: never touch the live poller DB/ESI/Discord.
# Run with `MIX_ENV=test mix test` (or `mix test.safe` for the live guard).
config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "priv/data/test.db"),
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	pool_size: 5,
	queue_target: 2000,
	queue_interval: 5000,
	log: false

# Never boot the dashboard in test: isolated DB, no HTTP listener.
config :marketmailer, MarketmailerWeb.Endpoint, server: false

config :marketmailer, ReadDatabase,
	database: System.get_env("MARKETMAILER_READ_DB", "priv/data/test_read.db"),
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	pool_size: 5,
	queue_target: 2000,
	queue_interval: 5000,
	log: false

config :marketmailer, :dashboard_enabled, false
config :marketmailer, :start_pollers, false
config :marketmailer, ecto_repos: [Database]
