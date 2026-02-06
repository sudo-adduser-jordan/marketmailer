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
  # instead of making a queue in gen server, configure postgres to not timeout requests in its queue
  queue_interval: System.schedulers_online() * 1000,
  timeout: System.schedulers_online() * 1000,
  # pool_size: System.schedulers_online() * 4,
  log: false

config :marketmailer,
  ecto_repos: [Marketmailer.Database]

config :marketmailer, Marketmailer.Mailer, adapter: Swoosh.Adapters.Gmail

config :marketmailer,
  mail_from: "",
  mail_to: ""

# Swoosh dev mailbox preview (optional)
# if Mix.env() == :dev do
#   config :swoosh, :api_client, Swoosh.ApiClient.Hackney
#   config :swoosh, serve_mailbox: true
# end
