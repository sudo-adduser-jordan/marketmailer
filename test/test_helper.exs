{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

# `mix test` is always safe alongside a live poller: refuse only on a DB
# collision (effective test DB == live file while a poller holds it).
# The poller detection lives in Mix.Tasks.Test.Safe so `task test` and
# plain `mix test` share exactly the same guard; `config/test.exs`
# already isolates pollers/ESI/DB otherwise. (This helper therefore
# depends on the compiled lib/ tree — every test entrypoint compiles it
# first.) `test_db` is the effective DB path: config/test.exs defaults
test_db =
	case System.get_env("MARKETMAILER_DB") do
		path when path in [nil, ""] -> "priv/data/test.db"
		path -> path
	end

live_db = "priv/data/marketmailer.db"

if Mix.Tasks.Test.Safe.poller_running?() and Path.expand(test_db) == Path.expand(live_db) do
	raise "Refusing: a live poller seems to be running and the test DB #{test_db} collides with the live #{live_db} " <>
					"(see `ps aux | grep -F marketmailer`). Unset MARKETMAILER_DB " <>
					"(tests default to isolated priv/data/test.db) or point it at a tmp file."
end

ExUnit.start()
