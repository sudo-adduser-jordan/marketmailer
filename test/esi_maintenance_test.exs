defmodule ESI.MaintenanceTest do
	use ExUnit.Case, async: false

	import ExUnit.CaptureLog

	setup do
		MarketmailerTest.Fixtures.ensure_ets(:esi_error_state)
		MarketmailerTest.Fixtures.reset_esi_maintenance()
		ESI.Maintenance.subscribe(self())

		# The legacy edge tests below assert immediate announcements.
		Application.put_env(:marketmailer, :esi_maintenance,
			announce_grace_ms: 0,
			close_grace_ms: 0
		)

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

	test "a window that closes inside the announce grace is never announced" do
		Application.put_env(:marketmailer, :esi_maintenance,
			announce_grace_ms: 100,
			close_grace_ms: 0
		)

		ESI.Maintenance.down(:timeout)
		assert ESI.Maintenance.down?()
		Process.sleep(20)
		ESI.Maintenance.up()

		refute_receive {:esi_maintenance, :down, _event}, 300
		refute_receive {:esi_maintenance, :up, _event}, 100
		refute ESI.Maintenance.down?()
	end

	test "a window that outlives the announce grace is announced" do
		Application.put_env(:marketmailer, :esi_maintenance,
			announce_grace_ms: 50,
			close_grace_ms: 0
		)

		ESI.Maintenance.down(%{status: 503, url: "https://esi.evetech.net/v1/markets/1/orders/"})

		assert_receive {:esi_maintenance, :down, %{reason: "HTTP 503"}}, 1_000
	end

	test "a failure inside the close grace cancels the pending close" do
		Application.put_env(:marketmailer, :esi_maintenance,
			announce_grace_ms: 0,
			close_grace_ms: 100
		)

		ESI.Maintenance.down(:timeout)
		assert_receive {:esi_maintenance, :down, _event}, 1_000

		ESI.Maintenance.up()
		ESI.Maintenance.down(:timeout)

		refute_receive {:esi_maintenance, :up, _event}, 300
		refute_receive {:esi_maintenance, :down, _event}, 100

		ESI.Maintenance.up()
		assert_receive {:esi_maintenance, :up, %{downtime_ms: _}}, 1_000
	end

	defp tick(pid) do
		send(pid, :tick)
		Process.sleep(100)
	end
end
