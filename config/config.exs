import Config

config :logger, :console,
	format: "$message\n",
	metadata: []

config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "marketmailer.db"),
	journal_mode: :wal,
	busy_timeout: 5000,
	log: false

config :marketmailer, :bot_options, %{
	consumer: Discord.Consumer,
	intents: [:guild_messages],
	wrapped_token: fn -> System.fetch_env!("DISCORD_TOKEN") end
}

config :marketmailer, ecto_repos: [Database]
