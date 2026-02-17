defmodule Marketmailer.Repo.Migrations.CreateRegisteredChannels do
	use Ecto.Migration

	def change do
		create table(:registered_channels, primary_key: false) do
			add :guild_id, :bigint, primary_key: true
			add :channel_id, :bigint, null: false
			timestamps()
		end
	end
end
