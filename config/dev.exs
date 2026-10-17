import Config

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

config :marketmailer, Database, database: database

config :marketmailer, MarketmailerWeb.Endpoint,
	http: [ip: {127, 0, 0, 1}, port: port],
	server: dashboard_enabled,
	secret_key_base: "dev-secret-key-base-at-least-64-bytes-long-for-live-dashboard-only-0123456789"

config :marketmailer, :dashboard_enabled, dashboard_enabled
config :marketmailer, :start_pollers, start_pollers
