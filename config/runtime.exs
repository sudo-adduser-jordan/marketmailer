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

	# LiveDashboard (`/dashboard`). DASHBOARD_ENABLED=false skips the
	# endpoint; DASHBOARD_PORT defaults to 4000. Set DASHBOARD_USER and
	# DASHBOARD_PASSWORD to require HTTP basic auth, SECRET_KEY_BASE to a
	# 64+ byte secret to enable the dashboard in prod. A missing secret
	# only skips the dashboard with a warning (like the Discord bot) so
	# the poller keeps running.
	dashboard_enabled =
		case System.get_env("DASHBOARD_ENABLED") do
			v when v in ["0", "false", "no"] -> false
			_ -> true
		end

	config :marketmailer, Database,
		database: database,
		priv: "priv/repo",
		journal_mode: :wal,
		busy_timeout: 5_000,
		pool_size: 20,
		queue_target: 2_000,
		queue_interval: 5_000,
		log: false

	config :marketmailer, :dashboard_enabled, dashboard_enabled

	# The bot reads DISCORD_TOKEN lazily (&Marketmailer.BotSupervisor.token!/0),
	# so a missing token only skips the bot with a warning instead of
	# crashing boot.
	config :marketmailer, :start_pollers, true

	if dashboard_enabled do
		case System.get_env("SECRET_KEY_BASE") do
			key when key in [nil, ""] ->
				IO.puts(
					:stderr,
					"warning: SECRET_KEY_BASE not set — LiveDashboard disabled (set SECRET_KEY_BASE to enable it)"
				)

				config :marketmailer, :dashboard_enabled, false

			secret ->
				port =
					case System.get_env("DASHBOARD_PORT") do
						nil -> 4000
						"" -> 4000
						str -> String.to_integer(str)
					end

				config :marketmailer, MarketmailerWeb.Endpoint,
					http: [ip: {0, 0, 0, 0}, port: port],
					url: [host: System.get_env("DASHBOARD_HOST", "localhost"), port: port],
					secret_key_base: secret,
					server: true

				config :marketmailer, :dashboard_password, System.get_env("DASHBOARD_PASSWORD")
				config :marketmailer, :dashboard_user, System.get_env("DASHBOARD_USER")
		end
	end
end
