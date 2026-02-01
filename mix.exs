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
      # extra_applications: [:logger],
      extra_applications: [:logger, :inets],
      mod: {Marketmailer.Application, []}
    ]
  end

  defp deps do
    [
        {:req, "~> 0.5.0"},
        {:ecto_sql, "~> 3.0"},
        {:postgrex, ">= 0.0.0"},
        {:swoosh, "~> 1.19"},
        {:gen_smtp, "~> 1.0"},
        {:esi_eve_online, git: "https://github.com/marcinruszkiewicz/esi_eve_online.git"}
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
        "run --no-halt"
      ]
    ]
  end
end
