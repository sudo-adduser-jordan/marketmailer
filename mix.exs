defmodule Marketmailer.MixProject do
	use Mix.Project

	def project do
		[
			app: :marketmailer,
			version: "0.0.1",
			elixir: "~> 1.19",
			start_permanent: Mix.env() == :prod,
			deps: deps(),
			aliases: aliases()
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
			{:postgrex, ">= 0.0.0"},
			{:swoosh, "~> 1.21"},
			{:hackney, "~> 1.9"},
                {:quokka, "~> 2.11", only: [:dev, :test], runtime: false},
		]
	end

	defp aliases do
		[
			setup: [
				"deps.get",
				"ecto.setup"
			],
			"ecto.setup": [
				"ecto.create",
				"ecto.migrate",
				"run priv/repo/seeds.exs"
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
