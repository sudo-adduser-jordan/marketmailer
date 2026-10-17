import Config

# Shared Database repo settings, imported by config/config.exs. Each
# environment overrides :database (and, under test, :pool_size): repeated
# `config` calls merge into this base rather than replacing it.
config :marketmailer, Database,
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 15_000,
	# Writes are serialized through Database.Queue, so the pool mostly serves
	# reads; these keep a read burst from being dropped while it drains.
	pool_size: 20,
	queue_target: 5_000,
	queue_interval: 10_000,
	# Default exqlite cache is 2 MB, small for a ~730 MB database.
	cache_size: -64_000,
	log: false
