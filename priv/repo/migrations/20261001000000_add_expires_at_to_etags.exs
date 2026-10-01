defmodule Database.Migrations.AddExpiresAtToEtags do
	use Ecto.Migration

	def change do
		alter table(:etags) do
			add :expires_at, :bigint
		end
	end
end
