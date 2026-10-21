defmodule Marketmailer.RegionsTest do
	use ExUnit.Case, async: false

	setup do
		Database.delete_all("regions")
		on_exit(fn -> Database.delete_all("regions") end)
		:ok
	end

	test "lists SDE region ids in id order" do
		Database.insert_all("regions", [
			%{region_id: 10_001_004, name: "Exordium"},
			%{region_id: 10_000_002, name: "The Forge"}
		])

		assert Marketmailer.Regions.ids() == [10_000_002, 10_001_004]
	end

	test "returns no regions before the SDE import" do
		assert Marketmailer.Regions.ids() == []
	end
end
