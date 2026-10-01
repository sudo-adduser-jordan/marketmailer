defmodule Mix.Tasks.Test.Safe do
	@shortdoc "Guard against a live poller, then run tests in MIX_ENV=test"

	@moduledoc """
	Guards the suite against a live poller, then runs tests in `MIX_ENV=test`.

	Refuses when a `mix run` / `mix start` / `iex -S mix` process is visible
	(best-effort via `pgrep`). A stale `-wal` sidecar alone is only a warning:
	WAL files can linger after an unclean shutdown without any live holder.
	"""

	use Mix.Task

	@impl true
	def run(args) do
		db = System.get_env("MARKETMAILER_DB", "marketmailer.db")

		if poller_running?() do
			Mix.shell().error(
				"Refusing: a live poller seems to be running (see `ps aux | grep -F marketmailer`). " <>
					"Stop `mix run` first, or set MARKETMAILER_DB to an isolated file."
			)

			exit({:shutdown, 1})
		end

		if stale_sidecar?(db) do
			Mix.shell().info("test.safe: stale #{db}-wal sidecar present, no live poller found; continuing")
		end

		if Mix.env() == :test do
			Mix.Task.run("test", args)
		else
			{_, code} =
				System.cmd("mix", ["test" | args],
					env: [{"MIX_ENV", "test"}],
					into: IO.stream(:stdio, :line)
				)

			if code != 0, do: exit({:shutdown, code})
		end
	end

	defp stale_sidecar?(db), do: File.exists?(db <> "-wal") or File.exists?(db <> "-shm")

	# A live `mix run --no-halt` / `mix start` / `iex -S mix run` for this
	# project. Excludes this task's own re-exec chain.
	defp poller_running? do
		case System.cmd("pgrep", ["-af", "mix.*(run|start)|iex.*mix"], stderr_to_stdout: true) do
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
