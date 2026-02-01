defmodule Marketmailer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:market_etags, [:named_table, :set, :public])
    children = [
      # Marketmailer.Database,
      # Marketmailer.Mailer,
      {Registry, [keys: :unique, name: Marketmailer.Registry]},
      Marketmailer.RegionDynamicSupervisor,
      Marketmailer.RegionManager
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
