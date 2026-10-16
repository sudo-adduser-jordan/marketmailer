defmodule Mix.Tasks.Test.Safe do
	use Mix.Task

	@live_db "priv/data/marketmailer.db"

	@impl true
	def run(args) do
		test_db = System.get_env("MARKETMAILER_DB", "priv/data/test.db")

		cond do
			!poller_running?() ->
				if stale_sidecar?(test_db) do
					Mix.shell().info("test.safe: stale #{test_db}-wal sidecar present, no live poller found; continuing")
				end

				run_tests(args)

			db_collision?(test_db) ->
				Mix.shell().error(
					"Refusing: a live poller seems to be running and the test DB " <>
						"#{test_db} collides with the live #{@live_db} " <>
						"(see `ps aux | grep -F marketmailer`). Unset MARKETMAILER_DB " <>
						"(tests default to isolated priv/data/test.db) or point it at a tmp file."
				)

				exit({:shutdown, 1})

			true ->
				Mix.shell().info(
					"test.safe: live poller detected but test DB is isolated " <>
						"(#{test_db} vs live #{@live_db}); continuing"
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
						{"MARKETMAILER_DB", db}
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

	def poller_running? do
		case System.cmd("pgrep", ["-af", "mix.*(run|start)|iex.*mix|bin/marketmailer|beam.*marketmailer"],
					 stderr_to_stdout: true
				 ) do
			{out, 0} ->
				out
				|> String.split("\n", trim: true)
				|> Enum.reject(&String.contains?(&1, "pgrep"))
				|> Enum.reject(&String.contains?(&1, "test.safe"))
				|> Enum.reject(&String.contains?(&1, "_build/test"))
				|> Enum.reject(&String.contains?(&1, "mix test"))
				|> Enum.any?()

			{_out, _} ->
				false
		end
	rescue
		_ -> false
	end
end
