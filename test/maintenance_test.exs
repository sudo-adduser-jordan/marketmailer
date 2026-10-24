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
	end

	test "work is paused during eve online maintance disconnect" do
	end

	test "work is successfully resumed" do
	end
end
