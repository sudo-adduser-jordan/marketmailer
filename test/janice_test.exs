defmodule Janice.CaptureTest do
	use ExUnit.Case, async: true

	setup do
		ensure_cache_table()
		:ets.delete(:janice_chart_cache, 1_001)

		on_exit(fn -> :ets.delete(:janice_chart_cache, 1_001) end)

		:ok
	end

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

	test "is installed" do
	end

	test "browser is installed" do
	end

	test "caputures item graph" do
	end

	test "item graph is padded" do
	end

	test "caches exists" do
	end

	test "caches graph image" do
	end

	test "image size matches error and placeholder images" do
	end

	test "missing playwright fallback" do
	end
end
