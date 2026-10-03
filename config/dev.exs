import Config

# Local shell (`task dev`): isolated by default so it coexists with the prod
# daemon (`task start`, :4000 + priv/data/marketmailer.db). Dev gets
# http://localhost:4001/dashboard + priv/data/dev.db and no Discord gateway
# connection (prod keeps the gateway). Overrides: DASHBOARD_PORT,
# DASHBOARD_ENABLED=false, START_POLLERS=false (lightweight shell without ESI
# polling), MARKETMAILER_DEV_DB (explicit path for `mix run` without the task
# wrapper), DEV_DISCORD_TOKEN (opt into the bot; steals prod's gateway).
dashboard_enabled =
	case System.get_env("DASHBOARD_ENABLED") do
		v when v in ["0", "false", "no"] -> false
		_ -> true
	end

port =
	case System.get_env("DASHBOARD_PORT") do
		nil -> 4001
		"" -> 4001
		str -> String.to_integer(str)
	end

start_pollers =
	case System.get_env("START_POLLERS") do
		v when v in ["0", "false", "no"] -> false
		_ -> true
	end

database =
	System.get_env("MARKETMAILER_DEV_DB") ||
		System.get_env("MARKETMAILER_DB", "priv/data/dev.db")

config :marketmailer, Database,
	database: database,
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	pool_size: 20,
	queue_target: 2000,
	queue_interval: 5000,
	log: false

config :marketmailer, MarketmailerWeb.Endpoint,
	http: [ip: {127, 0, 0, 1}, port: port],
	server: dashboard_enabled,
	secret_key_base: "dev-secret-key-base-at-least-64-bytes-long-for-live-dashboard-only-0123456789"

config :marketmailer, :dashboard_enabled, dashboard_enabled
config :marketmailer, :start_pollers, start_pollers
