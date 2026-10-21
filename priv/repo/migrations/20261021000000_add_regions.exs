defmodule Database.Migrations.AddRegions do
	use Ecto.Migration

	# SDE region cache: the poller list is derived from mapRegions.jsonl instead
	# of a hardcoded id range, so a missing region (e.g. Exordium 10001004) can
	# never be silently skipped again.
	def change do
		create table(:regions, primary_key: false) do
			add :region_id, :integer, primary_key: true
			add :name, :string, null: false
		end
	end
end
