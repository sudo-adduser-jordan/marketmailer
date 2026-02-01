import Config

config :esi_eve_online,
  user_agent: "MyCoolApp/1.0 (email@example.com)"

# config :marketmailer, ecto_repos: [Marketmailer.Database]
# config :marketmailer, Marketmailer.Database,
#   username: "postgres",
#   password: "postgres",
#   database: "eve",
#   hostname: "localhost",
#   pool_size: 10,
#   log: false

config :swoosh, :api_client, false
config :marketmailer, Marketmailer.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: "SG.x.x"
