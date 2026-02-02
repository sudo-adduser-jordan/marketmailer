import Config

config :logger, :console,
  format: "$message\n",
  metadata: []

config :esi_eve_online,
  user_agent: "lostcoastwizard > Beam me up, Scotty!"

config :marketmailer, ecto_repos: [Marketmailer.Database]
config :marketmailer, Marketmailer.Database,
  username: "postgres",
  password: "postgres",
  database: "postgres",
  hostname: "localhost",
  pool_size: System.schedulers_online(),
  queue_target: 1000, # wait
  queue_interval: 5000, # health
  log: false

config :swoosh, :api_client, false
config :marketmailer, Marketmailer.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: "SG.x.x"
