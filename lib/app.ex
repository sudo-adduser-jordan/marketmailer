defmodule Marketmailer.Application do
	use Application

	require Logger

	@legacy_tables ["systems", "names", "discord", "etags", "market"]

	@impl true
	def start(_type, _args) do
		:ets.new(:market_cache, [:named_table, :set, :public, read_concurrency: true])
		:ets.new(:esi_error_state, [:named_table, :set, :public, read_concurrency: true])

		:ok = migrate()

		children = [
			Database,
			EtagCache,
			{Registry, keys: :unique, name: Marketmailer.Registry},
			{DynamicSupervisor, strategy: :one_for_one, name: Marketmailer.PageSup},
			{Task.Supervisor, name: Marketmailer.TaskSup}
			# Marketmailer.RegionManagerSupervisor,
			# {Nostrum.Bot, Application.fetch_env!(:marketmailer, :bot_options)},
			# Marketmailer.MailWorker,
		]

		opts = [
			strategy: :one_for_one,
			name: Marketmailer.Supervisor
		]

		Supervisor.start_link(children, opts)
	end

	# Runs pending priv/repo/migrations on every boot so `mix run`/containers
	# never need a separate migrate step. Databases created before migrations
	# existed have the tables but no schema_migrations bookkeeping; those are
	# dropped once (data is derived cache) and rebuilt.
	defp migrate do
		path = Path.join(:code.priv_dir(:marketmailer), "repo/migrations")

		fun = fn repo ->
			drop_legacy(repo)
			Ecto.Migrator.run(repo, path, :up, all: true)
		end

		case Ecto.Migrator.with_repo(Database, fun) do
			{:ok, _, _} -> :ok
			{:error, error} -> raise "migrations failed: #{inspect(error)}"
		end
	end

	defp drop_legacy(repo) do
		%{rows: rows} =
			repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")

		names = MapSet.new(rows, fn [name] -> name end)

		if MapSet.size(names) > 0 and not MapSet.member?(names, "schema_migrations") do
			Logger.warning("pre-migration database detected; dropping #{Enum.join(@legacy_tables, ", ")}")

			Enum.each(@legacy_tables, fn table ->
				repo.query!("DROP TABLE IF EXISTS #{table}")
			end)

			repo.query!("DROP VIEW IF EXISTS marketView")
		end
	end
end
