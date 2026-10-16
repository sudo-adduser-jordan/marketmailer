defmodule Database.Migrations.AddUrlToMarket do
	use Ecto.Migration

	def change do
		if !column_exists?("market", :url) do
			alter table(:market) do
				add :url, :string
			end
		end

		create_if_not_exists index(:market, [:url])
	end

	defp column_exists?(table, column) do
		%{rows: rows} =
			repo().query!("SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?", [table, to_string(column)])

		match?([[count]] when count > 0, rows)
	end
end
