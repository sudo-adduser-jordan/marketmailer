import Config

# Prod defaults; `config/runtime.exs` overrides port/secret/auth from env.
config :marketmailer, MarketmailerWeb.Endpoint, server: true
config :marketmailer, :dashboard_enabled, true
