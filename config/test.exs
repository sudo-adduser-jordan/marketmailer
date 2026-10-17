import Config

config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "priv/data/test.db"),
	pool_size: 5

config :marketmailer, MarketmailerWeb.Endpoint, server: false
# Same directory as production, separate sink: a test run must never delete or
# append to the live `logs/errors.jsonl`.
config :marketmailer, :dashboard_enabled, false
config :marketmailer, :error_log_path, "logs/test.jsonl"
config :marketmailer, :start_pollers, false
