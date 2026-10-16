{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

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
