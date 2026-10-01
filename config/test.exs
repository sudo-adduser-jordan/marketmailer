import Config

# Isolated dev-test env: never touch the live poller DB/ESI/Discord.
# Run with `MIX_ENV=test mix test` (or `mix test.safe` for the live guard).
config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "test.db"),
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	log: false

config :marketmailer, :start_pollers, false
config :marketmailer, ecto_repos: [Database]
