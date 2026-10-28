defmodule Marketmailer.MixProject do
	use Mix.Project

	def project do
		[
			app: :marketmailer,
			version: "0.0.1",
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
			extra_applications: [:logger, :inets, :os_mon],
			mod: {Marketmailer.Application, []}
		]
	end

	defp deps do
		[
			{:req, "~> 0.7"},
			{:ecto_sql, "~> 3.0"},
			{:ecto_sqlite3, "~> 0.18"},
			{:nostrum, github: "Kraigie/nostrum"},
			{:playwright_ex, "~> 0.15.0"},
			{:castle, "~> 1.0"},
			{:phoenix, "~> 1.8"},
			{:phoenix_pubsub, "~> 2.1"},
			{:phoenix_live_view, "~> 1.1"},
			{:phoenix_live_dashboard, "~> 0.8"},
			{:ecto_sqlite3_extras, "~> 1.2"},
			{:telemetry_metrics, "~> 1.0"},
			{:telemetry_poller, "~> 1.0"},
			{:bandit, "~> 1.0"},
			{:jason, "~> 1.4"},
			{:quokka, "~> 2.11", only: [:dev, :test], runtime: false}
		]
	end

	defp elixirc_paths(:test), do: elixirc_paths(:dev) ++ ["test/support"]
	defp elixirc_paths(_env), do: ["lib", "hendricks_formatter.ex"]

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

	defp upgrade_baselines do
		vsn = Mix.Project.config()[:version]

		Path.wildcard("releases/marketmailer-*.tar.gz")
		|> Enum.map(&(&1 |> Path.basename(".tar.gz") |> String.trim_leading("marketmailer-")))
		|> Enum.filter(&(Version.compare(&1, vsn) == :lt))
		|> Enum.sort({:desc, Version})
		|> Enum.take(1)
		|> Enum.map(&"tar:releases/marketmailer-#{&1}.tar.gz")
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
