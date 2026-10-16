defmodule Mix.Tasks.Sde.ImportTest do
		use ExUnit.Case, async: true

		test "composes NPC station names from SDE reference maps" do
				alias Mix.Tasks.Sde.Import, as: SdeImport

				lookups = %{
						systems: %{30_000_142 => "Jita", 30_000_140 => "Maurasi", 30_100_000 => "Zarzakh"},
						corps: %{
								1_000_035 => "Caldari Navy",
								1_000_033 => "Caldari Business Tribunal",
								1_000_438 => "Deathless Custodians"
						},
						ops: %{14 => "Assembly Plant", 121 => "- The Fulcrum"},
						planets: %{40_009_082 => %{index: 4}, 40_008_900 => %{index: 8}, 40_009_100 => %{index: 9}},
						moons: %{40_009_087 => %{planet_id: 40_009_082, index: 4}, 40_008_952 => %{planet_id: 40_008_900, index: 14}},
						stars: MapSet.new([40_488_503])
				}

				assert %{id: 60_003_760, name: "Jita IV - Moon 4 - Caldari Navy Assembly Plant"} =
													SdeImport.compose_station_name(
															%{
																	"_key" => 60_003_760,
																	"solarSystemID" => 30_000_142,
																	"orbitID" => 40_009_087,
																	"ownerID" => 1_000_035,
																	"operationID" => 14,
																	"useOperationName" => true
															},
															lookups
													)

				assert %{id: 60_003_454, name: "Maurasi VIII - Moon 14 - Caldari Business Tribunal"} =
													SdeImport.compose_station_name(
															%{
																	"_key" => 60_003_454,
																	"solarSystemID" => 30_000_140,
																	"orbitID" => 40_008_952,
																	"ownerID" => 1_000_033,
																	"operationID" => 40,
																	"useOperationName" => false
															},
															lookups
													)

				assert %{id: 60_003_455, name: "Jita IX - Caldari Navy Assembly Plant"} =
													SdeImport.compose_station_name(
															%{
																	"_key" => 60_003_455,
																	"solarSystemID" => 30_000_142,
																	"orbitID" => 40_009_100,
																	"ownerID" => 1_000_035,
																	"operationID" => 14,
																	"useOperationName" => true
															},
															lookups
													)

				assert %{id: 60_015_187, name: "Zarzakh - Deathless Custodians - The Fulcrum"} =
													SdeImport.compose_station_name(
															%{
																	"_key" => 60_015_187,
																	"solarSystemID" => 30_100_000,
																	"orbitID" => 40_488_503,
																	"ownerID" => 1_000_438,
																	"operationID" => 121,
																	"useOperationName" => true
															},
															lookups
													)

				base = %{
						"_key" => 60_003_760,
						"solarSystemID" => 30_000_142,
						"orbitID" => 40_009_087,
						"ownerID" => 1_000_035,
						"operationID" => 14,
						"useOperationName" => true
				}

				assert SdeImport.compose_station_name(%{base | "solarSystemID" => 9_999_999}, lookups) == nil
				assert SdeImport.compose_station_name(%{base | "orbitID" => 9_999_999}, lookups) == nil
				assert SdeImport.compose_station_name(%{base | "ownerID" => 9_999_999}, lookups) == nil
				assert SdeImport.compose_station_name(%{base | "operationID" => 9_999_999}, lookups) == nil
				assert SdeImport.compose_station_name(%{"_key" => "bogus"}, lookups) == nil
		end
end
