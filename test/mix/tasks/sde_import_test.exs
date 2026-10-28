defmodule Mix.Tasks.Sde.ImportTest do
	use ExUnit.Case, async: false

	test "sde checksum" do
		assert Mix.Tasks.Sde.Import.resolve_build(["3569502"]) == "3569502"
		assert Mix.Tasks.Sde.Import.resolve_build([" 3569502 "]) == "3569502"

		assert Mix.Tasks.Sde.Import.sde_dir("3569502") == Path.join(["priv", "data", "sde", "3569502"])

		zip_name = "eve-online-static-data-3569502-jsonl.zip"
		zip = Path.join(Mix.Tasks.Sde.Import.sde_dir("3569502"), zip_name)

		assert Path.basename(zip) == zip_name
		assert Path.dirname(zip) == Mix.Tasks.Sde.Import.sde_dir("3569502")
	end

	test "database tables exist" do
		%{rows: rows} = Database.query!("SELECT name FROM sqlite_master WHERE type = 'table'")
		tables = MapSet.new(rows, fn [name] -> name end)

		for table <- ~w(names systems regions etags market contracts contract_items schema_migrations) do
			assert MapSet.member?(tables, table), "missing #{table}"
		end
	end

	test "database tables match sde" do
		assert ~w(id name is_capital_ship) -- columns("names") == []
		assert ~w(system_id name security_status region_name) -- columns("systems") == []
		assert ~w(region_id name) -- columns("regions") == []

		regions = %{10_000_043 => "Domain", 10_000_002 => "The Forge"}

		assert Mix.Tasks.Sde.Import.region_rows(regions) == [
						 %{region_id: 10_000_002, name: "The Forge"},
						 %{region_id: 10_000_043, name: "Domain"}
					 ]

		assert Mix.Tasks.Sde.Import.capital_ship_group?(485)
		assert Mix.Tasks.Sde.Import.capital_ship_group?(30)
		refute Mix.Tasks.Sde.Import.capital_ship_group?(513)
		refute Mix.Tasks.Sde.Import.capital_ship_group?(902)
	end

	defp columns(table) do
		%{rows: rows} = Database.query!("PRAGMA table_info(\"#{table}\")")
		Enum.map(rows, fn row -> Enum.at(row, 1) end)
	end
end
