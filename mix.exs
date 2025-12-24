defmodule Marketmailer.MixProject do
  use Mix.Project

  def project do
    [
      app: :marketmailer,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Marketmailer.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5.0"},
    #   {:ecto_sql, "~> 3.0"},
    #   {:postgrex, ">= 0.0.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
    #   test: ["ecto.create", "ecto.migrate", "test"],
      test: ["test"],
      format: ["format --check-formatted"]
    ]
  end
end
