defmodule Marketmailer.RegionManagerSupervisorTest do
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

		assert Marketmailer.RegionManagerSupervisor.sde_region_ids() == [10_000_002, 10_001_004]
	end

	test "returns no region ids before the SDE import" do
		assert Marketmailer.RegionManagerSupervisor.sde_region_ids() == []
	end
end
