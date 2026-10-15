defmodule Database.Migrations.DropSyncWatermark do
	use Ecto.Migration

	# Leftover from the removed write -> read copy layer (Market.Sync kept
	# its (updated_at, order_id) cursor in this table on the read database).
	# Single-DB mode has no watermark; drop it where it exists.
	def up do
		execute("DROP TABLE IF EXISTS _sync_watermark")
	end

	def down do
		:ok
	end
end
