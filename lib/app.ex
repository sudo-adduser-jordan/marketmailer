defmodule Marketmailer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Marketmailer.Database,
      Marketmailer.Client,
      # Marketmailer.Mailer,
    ]

    opts = [strategy: :one_for_one, name: Marketmailer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
