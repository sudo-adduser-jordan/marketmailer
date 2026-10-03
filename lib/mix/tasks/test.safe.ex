defmodule Mix.Tasks.Test.Safe do
	@shortdoc "Run tests in MIX_ENV=test, safe alongside a live poller when DB-isolated"

	@moduledoc """
	Grants the suite safe passage alongside an always-on live poller, then
	runs tests in `MIX_ENV=test`.

	The suite never touches the live poller: `config/test.exs` disables
	pollers (`start_pollers: false`), stubs ESI (maintenance ETS + fixtures),
	and defaults to isolated `priv/data/test.db` + `priv/data/test_read.db`
	(or per-suite tmp files). A live
	prod daemon (`task start`, i.e. a Castle release, `bin/marketmailer`) or a
	dev shell (`task dev`) is therefore
	allowed to keep running as long as the test DB files are isolated from the
	live `priv/data/marketmailer.db` + `priv/data/marketmailer_read.db`. Refusal happens only on a DB collision (e.g.
	`MARKETMAILER_DB=priv/data/marketmailer.db` while a poller holds it).

	A stale `-wal`/`-shm` sidecar alone is only a warning: WAL files can
	linger after an unclean shutdown without any live holder.
	"""

	use Mix.Task

	@live_db "priv/data/marketmailer.db"
	@live_read_db "priv/data/marketmailer_read.db"

	@impl true
	def run(args) do
		# What the test run will actually use: explicit env wins, otherwise
		# config/test.exs defaults to priv/data/test.db (never the live default).
		test_db = System.get_env("MARKETMAILER_DB", "priv/data/test.db")
		test_read_db = System.get_env("MARKETMAILER_READ_DB", "priv/data/test_read.db")

		cond do
			!poller_running?() ->
				if stale_sidecar?(test_db) do
					Mix.shell().info("test.safe: stale #{test_db}-wal sidecar present, no live poller found; continuing")
				end

				run_tests(args)

			db_collision?(test_db) or db_collision?(test_read_db, @live_read_db) ->
				Mix.shell().error(
					"Refusing: a live poller seems to be running and the test DB " <>
						"#{test_db} (read: #{test_read_db}) collides with the live #{@live_db} " <>
						"(read: #{@live_read_db}) (see `ps aux | grep -F marketmailer`). Unset MARKETMAILER_DB " <>
						"(tests default to isolated priv/data/test.db) or point it at a tmp file."
				)

				exit({:shutdown, 1})

			true ->
				Mix.shell().info(
					"test.safe: live poller detected but test DB is isolated " <>
						"(#{test_db} / #{test_read_db} vs live #{@live_db} / #{@live_read_db}); continuing"
				)

				run_tests(args)
		end
	end

	defp run_tests(args) do
		if Mix.env() == :test do
			Mix.Task.run("test", args)
		else
			env =
				if db = System.get_env("MARKETMAILER_DB"),
					do: [
						{"MIX_ENV", "test"},
						{"MARKETMAILER_DB", db},
						{"MARKETMAILER_READ_DB", System.get_env("MARKETMAILER_READ_DB", "")}
					],
					else: [{"MIX_ENV", "test"}]

			{_, code} =
				System.cmd("mix", ["test" | args],
					env: env,
					into: IO.stream(:stdio, :line)
				)

			if code != 0, do: exit({:shutdown, code})
		end
	end

	defp db_collision?(test_db), do: db_collision?(test_db, @live_db)

	defp db_collision?(test_db, live_db) do
		Path.expand(test_db) == Path.expand(live_db)
	end

	defp stale_sidecar?(db), do: File.exists?(db <> "-wal") or File.exists?(db <> "-shm")

	# A live prod daemon (`task start`) or dev shell (`task dev`) for this
	# project — i.e. a Castle release (`bin/marketmailer ...`) or a
	# `beam.smp ... marketmailer` node. Best-effort via `pgrep`; excludes this
	# task's own re-exec chain.
	defp poller_running? do
		case System.cmd("pgrep", ["-af", "mix.*(run|start)|iex.*mix|bin/marketmailer|beam.*marketmailer"],
					 stderr_to_stdout: true
				 ) do
			{out, 0} ->
				out
				|> String.split("\n", trim: true)
				|> Enum.reject(&String.contains?(&1, "pgrep"))
				|> Enum.reject(&String.contains?(&1, "test.safe"))
				|> Enum.any?()

			{_out, _} ->
				false
		end
	rescue
		_ -> false
	end
end
