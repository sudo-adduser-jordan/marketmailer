import Config

db_path =
	case System.get_env("MARKETMAILER_DB") do
		path when path in [nil, ""] -> "priv/data/marketmailer.db"
		path -> path
	end

config :logger, :default_handler,
	level: :info,
	formatter: {Marketmailer.Log.Format, [pretty: true, color: true]}

import_config "repo.exs"

config :marketmailer, Database, database: db_path

config :marketmailer, MarketmailerWeb.Endpoint,
	url: [host: "localhost"],
	adapter: Bandit.PhoenixAdapter,
	render_errors: [formats: [html: MarketmailerWeb.ErrorHTML], layout: false],
	pubsub_server: Marketmailer.PubSub,
	live_view: [signing_salt: "marketmailer-dashboard"]

config :marketmailer, :bot_options, %{
	consumer: Discord.Consumer,
	intents: [:guild_messages],
	wrapped_token: &Discord.BotSupervisor.token!/0
}

config :marketmailer, :contracts,
	enabled: true,
	excluded_types: ["courier", "auction", "loan", "unknown"]

config :marketmailer, :dashboard_enabled, true
config :marketmailer, :dashboard_password, nil
config :marketmailer, :dashboard_user, nil

config :marketmailer, :esi_rate_limit,
	enabled: true,
	max_block_ms: 900_000,
	jitter_ms: 500

config :marketmailer, :maintenance,
	probe_host: "esi.evetech.net",
	probe_port: 443,
	probe_ms: 5_000,
	max_probe_ms: 60_000,
	probe_timeout_ms: 5_000,
	recheck_ms: 5_000,
	request_timeout_ms: 30_000

config :marketmailer, ecto_repos: [Database]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
