import Config

# Runtime (release) configuration. Evaluated at boot AND, via Castle, in a
# temporary VM running the target code before `bin/castle install`.
# Build-time `config/config.exs` holds defaults; this file wins at runtime
# so release tarballs stay env-agnostic (DB path, Discord token).
if config_env() == :prod do
	# An empty MARKETMAILER_DB (e.g. bare `export MARKETMAILER_DB=""` in `.env`)
	# counts as unset so it falls back to the default instead of pointing
	# Ecto at an invalid empty path.
	database =
		case System.get_env("MARKETMAILER_DB") do
			path when path in [nil, ""] -> "/data/marketmailer.db"
			path -> path
		end

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
