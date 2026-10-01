defmodule Marketmailer.BotSupervisor do
	use Supervisor

	def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

	# Release-safe token reader for Nostrum's `wrapped_token` option.
	# Releases serialize sys.config and only allow `&Mod.fun/arity`
	# captures — anonymous closures like `fn -> ... end` are rejected at
	# `mix release` time. MFA captures survive and still read the env
	# lazily at boot (missing token → bot :ignore, rest keeps running).
	def token!, do: System.fetch_env!("DISCORD_TOKEN")

	@impl true
	def init(opts) do
		# Building nostrum's child spec fetches and validates the token
		# (wrapped_token). It raises on a missing or invalid token, so catch it
		# here and :ignore - the bot gets dropped and the rest of the tree runs.
		bot = Supervisor.child_spec({Nostrum.Bot, opts}, restart: :temporary)
		Supervisor.init([bot], strategy: :one_for_one)
	rescue
		e ->
			Marketmailer.Log.warning(
				"discord_bot_disabled",
				%{reason: Exception.message(e)},
				"Discord bot disabled (rest continues): #{Exception.message(e)}"
			)

			:ignore
	end
end
