import Config

# Isolated dev-test env: never touch the live poller DB/ESI/Discord.
# `mix test` is safe by construction (test_helper.exs refuses on DB collision);
# `mix test.safe` is the explicit entrypoint with poller-status messaging.
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
config :marketmailer, :dashboard_enabled, false
config :marketmailer, :start_pollers, false
config :marketmailer, ecto_repos: [Database]
