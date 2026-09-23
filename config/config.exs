import Config

# Console handler: pretty JSON records (info/warning/error), keys colored per
# level, values colored by type.
config :logger, :default_handler,
	level: :info,
	formatter: {Marketmailer.Log.Format, [pretty: true, color: true]}

# Error-level events also go to logs/errors.jsonl (see lib/app.ex).

config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "marketmailer.db"),
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	log: false

config :marketmailer, :bot_options, %{
	consumer: Discord.Consumer,
	intents: [:guild_messages],
	wrapped_token: fn -> System.fetch_env!("DISCORD_TOKEN") end
}

config :marketmailer, ecto_repos: [Database]
