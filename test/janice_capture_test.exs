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

	test "Playwright adapter reports unavailable when its supervisor is absent" do
		assert {:error, :playwright_unavailable} = Janice.Playwright.capture(1_001, timeout: 10)
	end

	test "supervisor degrades to the static fallback when Playwright is missing" do
		assert :ignore = Janice.Supervisor.start_link(executable: "definitely-missing-playwright")
	end
end
