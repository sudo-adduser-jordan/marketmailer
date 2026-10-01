import Config

# An empty MARKETMAILER_DB (e.g. bare `export MARKETMAILER_DB=""` in `.env`)
# counts as unset so it falls back to the default instead of pointing Ecto
# at an invalid empty path.
db_path =
	case System.get_env("MARKETMAILER_DB") do
		path when path in [nil, ""] -> "priv/data/marketmailer.db"
		path -> path
	end

# Console handler: pretty JSON records (info/warning/error), keys colored per
# level, values colored by type.
config :logger, :default_handler,
	level: :info,
	formatter: {Marketmailer.Log.Format, [pretty: true, color: true]}

# Warning/error-level events also go to logs/errors.jsonl (see lib/app.ex).

config :marketmailer, Database,
	database: db_path,
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	pool_size: 20,
	queue_target: 2000,
	queue_interval: 5000,
	log: false

config :marketmailer, :bot_options, %{
	consumer: Discord.Consumer,
	intents: [:guild_messages],
	wrapped_token: &Marketmailer.BotSupervisor.token!/0
}

config :marketmailer, ecto_repos: [Database]

import_config "#{config_env()}.exs"
