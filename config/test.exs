import Config

# Same directory as production, separate sink: a test run must never delete or
# append to the live `logs/errors.jsonl`.
config :marketmailer, Database,
	database: System.get_env("MARKETMAILER_DB", "priv/data/test.db"),
	pool_size: 5

config :marketmailer, MarketmailerWeb.Endpoint, server: false
config :marketmailer, :dashboard_enabled, false
config :marketmailer, :error_log_path, "logs/test.jsonl"

# Fast, network-free watchdog: tests decide the probe outcome through
# :persistent_term and are messaged on every probe attempt.
config :marketmailer, :maintenance,
	probe_ms: 20,
	max_probe_ms: 40,
	probe_timeout_ms: 50,
	recheck_ms: 50,
	probe_fun: fn _host, _port, _timeout ->
		if pid = :persistent_term.get({:marketmailer_test, :probe_notify}, nil) do
			send(pid, {:probe, :network})
		end

		:persistent_term.get({:marketmailer_test, :probe_result}, {:error, :test})
	end

# No herd to spread in tests, and gate tests assert the first tick is prompt.
config :marketmailer, :poll_start_jitter_ms, 0
config :marketmailer, :start_pollers, false
