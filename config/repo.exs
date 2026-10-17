import Config

# Shared Database repo settings, imported by config/config.exs. Each
# environment overrides :database (and, under test, :pool_size): repeated
# `config` calls merge into this base rather than replacing it.
config :marketmailer, Database,
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 5000,
	pool_size: 20,
	queue_target: 2000,
	queue_interval: 5000,
	log: false
