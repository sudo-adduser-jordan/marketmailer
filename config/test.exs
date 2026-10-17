import Config

config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "priv/data/test.db"),
	pool_size: 5

# Same directory as production, separate sink: a test run must never delete or
# append to the live `logs/errors.jsonl`.
config :marketmailer, MarketmailerWeb.Endpoint, server: false
config :marketmailer, :dashboard_enabled, false
config :marketmailer, :error_log_path, "logs/test.jsonl"
# No herd to spread in tests, and gate tests assert the first tick is prompt.
config :marketmailer, :poll_start_jitter_ms, 0
config :marketmailer, :start_pollers, false
