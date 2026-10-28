defmodule ESI.MaintenanceTest do
	use ExUnit.Case, async: false

	import ExUnit.CaptureLog

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.reset_esi_maintenance()
		ESI.Maintenance.subscribe(self())

		on_exit(fn ->
			MarketmailerTest.Fixtures.reset_esi_maintenance()
			Application.delete_env(:marketmailer, :esi_maintenance)
		end)

		:ok
	end

	test "the first failure opens a window and later ones only extend it" do
		refute ESI.Maintenance.down?()

		assert :ok = ESI.Maintenance.down(%{status: 503, url: "https://esi.evetech.net/v1/markets/1/orders/"})
		assert ESI.Maintenance.down?()
		assert_receive {:esi_maintenance, :down, %{reason: "HTTP 503"}}

		assert :ok = ESI.Maintenance.down(%{status: 502, url: "https://esi.evetech.net/v1/markets/1/orders/"})
		refute_receive {:esi_maintenance, :down, _event}, 100
		assert ESI.Maintenance.down?()
		assert %{down: true, reason: "HTTP 503"} = ESI.Maintenance.state()
	end

	test "the first success closes the window and reports the downtime" do
		ESI.Maintenance.down(:timeout)
		assert_receive {:esi_maintenance, :down, %{reason: "timeout"}}

		Process.sleep(5)

		assert :ok = ESI.Maintenance.up()
		refute ESI.Maintenance.down?()
		assert_receive {:esi_maintenance, :up, %{downtime_ms: downtime}}
		assert downtime >= 0
		assert %{down: false} = ESI.Maintenance.state()

		assert :ok = ESI.Maintenance.up()
		refute_receive {:esi_maintenance, :up, _event}, 100
	end

	test "a window outlives the probe interval instead of expiring on its own" do
		ESI.Maintenance.down(:timeout)
		now = System.system_time(:millisecond)

		assert [{:maintenance_mode, until}] = :ets.lookup(:esi_error_state, :maintenance_mode)
		assert until > now + 60_000
		assert ESI.Maintenance.down?()
	end

	test "a stale window is reported once per report interval" do
		Application.put_env(:marketmailer, :esi_maintenance, stale_after_ms: 0, stale_every_ms: 60_000)
		ESI.Maintenance.down(:timeout)
		pid = Process.whereis(ESI.Maintenance)

		log = capture_log(fn -> tick(pid) end)
		assert log =~ "esi_maintenance_stale"

		again = capture_log(fn -> tick(pid) end)
		refute again =~ "esi_maintenance_stale"
	end

	defp tick(pid) do
		send(pid, :tick)
		Process.sleep(100)
	end
end
