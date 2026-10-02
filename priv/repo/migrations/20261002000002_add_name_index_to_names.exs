defmodule Database.Migrations.AddNameIndexToNames do
	use Ecto.Migration

	# Prefix search for check_market autocomplete over a ~17k-row names table.
	def change do
		create index(:names, [:name])
	end
end
