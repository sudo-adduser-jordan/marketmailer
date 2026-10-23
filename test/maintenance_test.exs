defmodule Marketmailer.MaintenanceTest do
	use ExUnit.Case, async: false

	alias Marketmailer.Maintenance

	setup do
		MarketmailerTest.Fixtures.reset_network()
		:persistent_term.put({:marketmailer_test, :probe_notify}, self())
		:persistent_term.put({:marketmailer_test, :probe_result}, {:error, :test})

		on_exit(fn ->
			:persistent_term.erase({:marketmailer_test, :probe_notify})
			:persistent_term.erase({:marketmailer_test, :probe_result})
			MarketmailerTest.Fixtures.reset_network()
		end)

		:ok
	end

	test "a disconnect halts and a successful probe resumes" do
		assert Maintenance.up?()
		assert :ok = Maintenance.subscribe(self())

		assert :ok = Maintenance.report_disconnect(:econnrefused)
		assert Maintenance.down?()
		assert_receive {:maintenance, :down}, 1_000
		assert_receive {:probe, :network}, 1_000

		:persistent_term.put({:marketmailer_test, :probe_result}, :ok)

		assert_receive {:maintenance, :up}, 1_000
		assert Maintenance.up?()

		flush_probes()
		refute_receive {:probe, :network}, 100
	end

	test "report_connected restores without waiting for a probe" do
		assert :ok = Maintenance.subscribe(self())

		Maintenance.report_disconnect(:etimedout)
		assert_receive {:maintenance, :down}, 1_000

		Maintenance.report_connected()

		assert_receive {:maintenance, :up}, 1_000
		assert Maintenance.up?()
	end

	test "repeated reports while down do not reset the probe cadence" do
		Maintenance.report_disconnect(:econnrefused)
		assert_receive {:probe, :network}, 1_000

		Maintenance.report_disconnect(:econnrefused)
		Maintenance.report_disconnect(:econnrefused)

		assert Maintenance.down?()
		assert_receive {:probe, :network}, 1_000
	end

	test "status defaults to up and carries the reason while down" do
		assert %{state: :up, reason: nil} = Maintenance.status()

		Maintenance.report_disconnect(:econnrefused)

		assert %{state: :down, reason: reason} = Maintenance.status()
		assert reason =~ "econnrefused"
	end

	defp flush_probes do
		receive do
			{:probe, :network} -> flush_probes()
		after
			0 -> :ok
		end
	end
end
