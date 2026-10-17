import Config

config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "priv/data/test.db"),
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	pool_size: 5,
	queue_target: 2000,
	queue_interval: 5000,
	log: false

config :marketmailer, MarketmailerWeb.Endpoint, server: false
# Same directory as production, separate sink: a test run must never delete or
# append to the live `logs/errors.jsonl`.
config :marketmailer, :dashboard_enabled, false
config :marketmailer, :error_log_path, "logs/test.jsonl"
config :marketmailer, :start_pollers, false
config :marketmailer, ecto_repos: [Database]
