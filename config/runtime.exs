import Config

# Runtime (release) configuration. Evaluated at boot AND, via Castle, in a
# temporary VM running the target code before `bin/castle install`.
# Build-time `config/config.exs` holds defaults; this file wins at runtime
# so release tarballs stay env-agnostic (DB path, Discord token).
if config_env() == :prod do
	database =
		System.get_env("MARKETMAILER_DB", "/data/marketmailer.db")

	config :marketmailer, Database,
		database: database,
		priv: "priv/repo",
		journal_mode: :wal,
		busy_timeout: 5_000,
		log: false

	# The bot reads DISCORD_TOKEN lazily (&Marketmailer.BotSupervisor.token!/0),
	# so a missing token only skips the bot with a warning instead of
	# crashing boot.
	config :marketmailer, :start_pollers, true
end
