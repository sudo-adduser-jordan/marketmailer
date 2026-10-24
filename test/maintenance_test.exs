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

	test "work is paused during a network disconnect" do
		Maintenance.subscribe()

		Maintenance.report_disconnect(:econnrefused)

		assert_receive {:maintenance, :down}, 1_000
		assert Maintenance.down?()
		assert %{state: :down, reason: reason} = Maintenance.status()
		assert reason =~ "econnrefused"
	end

	test "work is paused during eve online maintance disconnect" do
		:persistent_term.put({:marketmailer_test, :probe_result}, {:error, :timeout})

		Maintenance.subscribe()

		Maintenance.report_disconnect(:timeout)

		assert_receive {:maintenance, :down}, 1_000
		assert_receive {:probe, :network}, 1_000
		assert Maintenance.down?()
		refute_receive {:maintenance, :up}, 200
	end

	test "work is successfully resumed" do
		Maintenance.subscribe()

		Maintenance.report_disconnect(:econnrefused)
		assert_receive {:maintenance, :down}, 1_000

		:persistent_term.put({:marketmailer_test, :probe_result}, :ok)

		assert_receive {:probe, :network}, 1_000
		assert_receive {:maintenance, :up}, 1_000
		assert Maintenance.up?()
		assert %{state: :up, reason: nil} = Maintenance.status()
	end
end
