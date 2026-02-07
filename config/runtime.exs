import Config

config :marketmailer, Marketmailer.Mailer,
  adapter: Swoosh.Adapters.Gmail,
  access_token: {:system, "GMAIL_API_ACCESS_TOKEN"}
