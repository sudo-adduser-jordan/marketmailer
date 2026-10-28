import Config

config :marketmailer, Database,
	priv: "priv/repo",
	journal_mode: :wal,
	busy_timeout: 15_000,
	pool_size: 20,
	queue_target: 5_000,
	queue_interval: 10_000,
	cache_size: -64_000,
	log: false
