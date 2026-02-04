import Config

config :logger, :console,
  format: "$message\n",
  metadata: []

config :marketmailer, ecto_repos: [Marketmailer.Database]

config :marketmailer, Marketmailer.Database,
  username: "postgres",
  password: "postgres",
  database: "eve",
  hostname: "localhost",
  queue_interval: 69420,
  timeout: 69420,
  log: false

config :swoosh, :api_client, false

config :marketmailer, Marketmailer.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: "SG.x.x"
