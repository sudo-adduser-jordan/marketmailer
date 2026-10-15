{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

# `mix test` is always safe alongside a live poller: refuse only on a DB
# collision (effective test DB == live file while a poller holds it).
# Mirrors `Mix.Tasks.Test.Safe`; `config/test.exs` already isolates
# pollers/ESI/DB otherwise.
test_db =
	case System.get_env("MARKETMAILER_DB") do
		path when path in [nil, ""] -> "priv/data/test.db"
		path -> path
	end

live_db = "priv/data/marketmailer.db"

poller_running? =
	try do
		case System.cmd("pgrep", ["-af", "mix.*(run|start)|iex.*mix|bin/marketmailer|beam.*marketmailer"],
			 stderr_to_stdout: true
			) do
			{out, 0} ->
				out
				|> String.split("\n", trim: true)
				|> Enum.reject(&String.contains?(&1, "pgrep"))
				|> Enum.reject(&String.contains?(&1, "_build/test"))
				|> Enum.reject(&String.contains?(&1, "mix test"))
				|> Enum.any?()

			{_out, _} ->
				false
		end
	rescue
		_ -> false
	end

if poller_running? and Path.expand(test_db) == Path.expand(live_db) do
	raise "Refusing: a live poller seems to be running and the test DB #{test_db} collides with the live #{live_db} " <>
			"(see `ps aux | grep -F marketmailer`). Unset MARKETMAILER_DB " <>
			"(tests default to isolated priv/data/test.db) or point it at a tmp file."
end

ExUnit.start()
