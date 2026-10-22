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

# Public-contract pollers; contracts with an item value minus price at or above
# `min_margin` (100m ISK) are surfaced. See `Contracts` for the full defaults.
config :marketmailer, :contracts,
	enabled: true,
	excluded_types: ["courier", "auction", "loan", "unknown"]

config :marketmailer, :dashboard_enabled, true
config :marketmailer, :dashboard_password, nil
config :marketmailer, :dashboard_user, nil

# ESI bucket limiting: a 429 pauses the whole rate-limit group for Retry-After
# (capped at max_block_ms); every request in the group waits it out.
config :marketmailer, :esi_rate_limit,
	enabled: true,
	max_block_ms: 900_000,
	jitter_ms: 500

config :marketmailer, ecto_repos: [Database]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
