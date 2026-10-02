defmodule Janice.CaptureTest do
	use ExUnit.Case, async: true

	defmodule Adapter do
		def capture(type_id, opts) do
			case Keyword.fetch!(opts, :result) do
				{:ok, png} ->
					send(opts[:test_pid], {:captured, type_id})
					{:ok, png}

				{:error, reason} ->
					{:error, reason}
			end
		end
	end

	test "delegates capture to an injectable adapter" do
		assert {:ok, <<137, 80, 78, 71>>} =
						 Janice.Capture.capture(1_001,
							 adapter: Adapter,
							 result: {:ok, <<137, 80, 78, 71>>},
							 test_pid: self()
						 )

		assert_received {:captured, 1_001}
	end

	test "returns adapter failures without raising" do
		assert {:error, :timeout} =
						 Janice.Capture.capture(1_001, adapter: Adapter, result: {:error, :timeout})
	end

	test "builds a stable attachment filename" do
		assert Janice.Capture.filename(1_001) == "janice-1001.png"
	end

	test "exposes a stable fallback filename" do
		assert Janice.Capture.fallback_filename() == "janice-failed.png"
	end

	test "loads a PNG fallback image for failed captures" do
		body = Janice.Capture.fallback_image()

		assert is_binary(body)
		assert byte_size(body) > 0
		assert binary_part(body, 0, 4) == <<137, 80, 78, 71>>
	end

	test "Playwright adapter reports unavailable when its supervisor is absent" do
		ensure_playwright_supervisor_absent()

		assert {:error, :playwright_unavailable} = Janice.Playwright.capture(1_001, timeout: 10)
	end

	test "serves fresh cached charts without launching a browser" do
		ensure_cache_table()
		ensure_playwright_supervisor_absent()
		:ets.insert(:janice_chart_cache, {1_001, <<137, 80, 78, 71>>, System.monotonic_time(:millisecond)})

		assert {:ok, <<137, 80, 78, 71>>} = Janice.Playwright.capture(1_001, timeout: 10)
	end

	test "ignores expired cache entries" do
		ensure_cache_table()
		ensure_playwright_supervisor_absent()

		stale = System.monotonic_time(:millisecond) - Janice.Playwright.cache_ttl_ms() - 1
		:ets.insert(:janice_chart_cache, {1_001, <<137, 80, 78, 71>>, stale})

		assert {:error, :playwright_unavailable} = Janice.Playwright.capture(1_001, timeout: 10)
	end

	defp ensure_cache_table do
		if :ets.whereis(:janice_chart_cache) == :undefined do
			:ets.new(:janice_chart_cache, [:named_table, :set, :public])
		end

		:ok
	end

	test "supervisor degrades to the static fallback when Playwright is missing" do
		assert :ignore = Janice.Supervisor.start_link(executable: "definitely-missing-playwright")
	end

	# The app boots Janice.Supervisor (and PlaywrightEx.Supervisor, where
	# Playwright is installed) under `mix test`, so force the "absent"
	# precondition instead of assuming it. terminate_child is an explicit
	# request, so one_for_one does not restart it; nothing else in the
	# suite uses the real adapter.
	defp ensure_playwright_supervisor_absent do
		case Process.whereis(PlaywrightEx.Supervisor) do
			nil ->
				:ok

			pid ->
				if supervisor = Process.whereis(Janice.Supervisor) do
					:ok = Supervisor.terminate_child(supervisor, PlaywrightEx.Supervisor)
				else
					Process.exit(pid, :kill)
				end

				ref = Process.monitor(pid)
				assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
		end
	end
end
