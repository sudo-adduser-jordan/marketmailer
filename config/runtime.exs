import Config

if config_env() == :prod do
	database =
		case System.get_env("MARKETMAILER_DB") do
			path when path in [nil, ""] -> "/data/marketmailer.db"
			path -> path
		end

	dashboard_enabled =
		case System.get_env("DASHBOARD_ENABLED") do
			v when v in ["0", "false", "no"] -> false
			_ -> true
		end

	config :marketmailer, Database, database: database
	config :marketmailer, :dashboard_enabled, dashboard_enabled
	config :marketmailer, :start_pollers, true

	if dashboard_enabled do
		secret =
			case System.get_env("SECRET_KEY_BASE") do
				key when key in [nil, ""] -> :crypto.strong_rand_bytes(64) |> Base.encode64()
				key -> key
			end

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
