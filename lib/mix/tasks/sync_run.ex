defmodule Mix.Tasks.Sync.Run do
	# Manually runs the write -> read database sync once and exits.
	#
	# Usage: MIX_ENV=prod MARKETMAILER_DB=priv/data/marketmailer.db mix sync.run
	#
	# Starts only the two database repos (never pollers, bot, or dashboard),
	# so it is safe alongside the live daemon: the sync's chunked reads and
	# upserts ride WAL concurrency like any other reader/writer.
	use Mix.Task

	@shortdoc "Run the write -> read database sync once"

	@impl true
	def run(_args) do
		{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
		{:ok, _} = Database.start_link()
		{:ok, _} = ReadDatabase.start_link()

		case Market.Sync.run() do
			:ok ->
				Mix.shell().info("sync done")

			{:error, reason} ->
				Mix.raise("sync failed: #{reason}")
		end
	end
end
