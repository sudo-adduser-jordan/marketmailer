defmodule Database.Migrations.AddUpdatedAtIndexToMarket do
	use Ecto.Migration

	# The write -> read sync pages market by (updated_at, order_id); without
	# this index every chunk re-scans the full order table.
	def change do
		create index(:market, [:updated_at, :order_id])
	end
end
