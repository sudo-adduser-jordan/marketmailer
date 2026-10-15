defmodule MarketmailerTest.Fixtures do
	@moduledoc """
	Shared ExUnit fixtures.

	The suite never starts pollers (`config/test.exs`:
	`start_pollers: false`), so every test file is responsible for the
	handful of named processes/tables it needs:

	* named ETS tables — `ensure_ets/2` creates them once and is a no-op
		afterwards, so any number of test files may call it;
	* `Marketmailer.PageSup` / `Marketmailer.Registry` must be started with
		`start_supervised!` **from the test process** (ExUnit only tracks
		supervisors started there), which is why that part stays in each
		test's `setup`.

	Parking workers in ESI maintenance mode (`park_page_workers/0`) keeps
	every `PageWorker` off the network, so page fan-out and cycle tracking
	can be tested with no HTTP at all.
	"""

	@park_window_ms 120_000

	@doc "Create the named ETS table when it does not exist yet."
	def ensure_ets(name, opts \\ [:named_table, :set, :public]) do
		case :ets.whereis(name) do
			:undefined -> :ets.new(name, opts)
			_tid -> :ok
		end
	end

	@doc """
	Make ESI look like it is in maintenance for the next
	`@park_window_ms` ms and remove the entry again when the test ends.

	`PageWorker.handle_info(:work, ...)` checks
	`ESI.maintenance_active?()` before any fetch, so a fresh entry parks
	every worker on its own 10s ping timer.
	"""
	def park_page_workers do
		:ets.insert(:esi_error_state, {:maintenance_mode, System.system_time(:millisecond) + @park_window_ms})

		ExUnit.Callbacks.on_exit(fn ->
			:ets.delete(:esi_error_state, :maintenance_mode)
		end)

		:ok
	end
end
