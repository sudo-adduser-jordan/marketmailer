defmodule Marketmailer.BotSupervisor do
	use Supervisor

	require Logger

	def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

	@impl true
	def init(opts) do
		# Building nostrum's child spec fetches and validates the token
		# (wrapped_token). It raises on a missing or invalid token, so catch it
		# here and :ignore - the bot gets dropped and the rest of the tree runs.
		bot = Supervisor.child_spec({Nostrum.Bot, opts}, restart: :temporary)
		{:ok, Supervisor.init([bot], strategy: :one_for_one)}
	rescue
		e ->
			Logger.warning("Discord bot disabled (rest continues): #{Exception.message(e)}")
			:ignore
	end
end