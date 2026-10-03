defmodule Marketmailer.MixProject do
	use Mix.Project

	def project do
		[
			app: :marketmailer,
			version: "0.1.13",
			elixir: "~> 1.19",
			appup: "appup.exs",
			compilers: Mix.compilers() ++ [:appup],
			elixirc_paths: elixirc_paths(Mix.env()),
			start_permanent: Mix.env() == :prod,
			deps: deps(),
			aliases: aliases(),
			releases: releases()
		]
	end

	def application do
		[
			extra_applications: [:logger, :inets],
			mod: {Marketmailer.Application, []}
		]
	end

	defp deps do
		[
			{:req, "~> 0.5.0"},
			{:ecto_sql, "~> 3.0"},
			{:ecto_sqlite3, "~> 0.18"},
			# {:nostrum, "~> 0.10"},
			{:nostrum, github: "Kraigie/nostrum"},
			{:playwright_ex, "~> 0.12.1"},
			{:castle, "~> 1.0"},
			{:phoenix, "~> 1.8"},
			{:phoenix_pubsub, "~> 2.1"},
			{:phoenix_live_view, "~> 1.1"},
			{:phoenix_live_dashboard, "~> 0.8"},
			{:telemetry_metrics, "~> 1.0"},
			{:telemetry_poller, "~> 1.0"},
			{:bandit, "~> 1.0"},
			{:jason, "~> 1.4"},
			{:quokka, "~> 2.11", only: [:dev, :test], runtime: false}
		]
	end

	# Define which paths to include based on the environment
	defp elixirc_paths(_env) do
		# "." adds the root directory
		["lib", "hendricks_formatter.ex"]
	end

	# OTP release with Castle hot-upgrade support. The function wrapper
	# delays evaluation until Castle is compiled. `upgrade_from` lists the
	# baselines this version can hot-upgrade from; it is omitted entirely
	# until the first shipped tarball lands under artifacts/ (Castle
	# rejects an empty baseline list — a relup with no transitions is not
	# an upgrade plan). SemVer: bump mix.exs version for every
	# hot-upgradeable change, keep the shipped tarballs under artifacts/
	# for `tar:` specs.
	defp releases do
		[
			marketmailer: fn ->
				base = [include_executables_for: [:unix], include_erts: true]

				case upgrade_baselines() do
					[] -> Castle.customize(base)
					baselines -> Castle.customize(Keyword.put(base, :upgrade_from, baselines))
				end
			end
		]
	end

	# Newest shipped tarball older than the version being built (linear
	# deploys upgrade from the previous release; a relup from a version
	# to itself can never be installed, so the version being built is
	# always excluded). Missing files are skipped so a fresh checkout
	# still assembles; empty means a plain build with no upgrade path.
	defp upgrade_baselines do
		vsn = Mix.Project.config()[:version]

		Path.wildcard("artifacts/marketmailer-*.tar.gz")
		|> Enum.map(&(&1 |> Path.basename(".tar.gz") |> String.trim_leading("marketmailer-")))
		|> Enum.filter(&(Version.compare(&1, vsn) == :lt))
		|> Enum.sort({:desc, Version})
		|> Enum.take(1)
		|> Enum.map(&"tar:artifacts/marketmailer-#{&1}.tar.gz")
	end

	defp aliases do
		[
			setup: [
				"deps.get",
				"ecto.setup"
			],
			"ecto.setup": [
				"ecto.create",
				"ecto.migrate"
			],
			"ecto.reset": [
				"ecto.drop",
				"ecto.setup"
			],
			format: [
				"format --check-formatted"
			],
			start: [
				"setup",
				"run --no-halt"
			]
		]
	end
end
