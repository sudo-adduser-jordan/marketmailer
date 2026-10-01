defmodule Marketmailer.MixProject do
	use Mix.Project

	def project do
		[
			app: :marketmailer,
			version: "0.1.0",
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

	# Baseline release tarballs kept under artifacts/. Add a `tar:` entry
	# for each shipped version you want to support hot upgrades from.
	# Missing files are skipped so a fresh checkout still assembles.
	defp upgrade_baselines do
		Path.wildcard("artifacts/marketmailer-*.tar.gz")
		|> Enum.map(&("tar:" <> &1))
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
