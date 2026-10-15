defmodule Database.Migrations.AddUpdatedAtIndexToMarket do
	use Ecto.Migration

	# Ordering/filtering helper on write recency; without this index
	# updated_at-ordered scans re-scan the full order table.
	def change do
		create index(:market, [:updated_at, :order_id])
	end
end
