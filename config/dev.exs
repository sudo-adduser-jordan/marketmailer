import Config

# Local dashboard: http://localhost:4000/dashboard (no auth by default).
config :marketmailer, MarketmailerWeb.Endpoint,
	http: [ip: {127, 0, 0, 1}, port: 4000],
	server: true,
	secret_key_base: "dev-secret-key-base-at-least-64-bytes-long-for-live-dashboard-only-0123456789"

config :marketmailer, :dashboard_enabled, true
