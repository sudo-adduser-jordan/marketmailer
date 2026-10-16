defmodule Marketmailer.PageWorkerTest do
	use ExUnit.Case, async: true

	test "format_ttl renders mm:ss" do
		assert Marketmailer.PageWorker.format_ttl(60_000) == "01:00"
		assert Marketmailer.PageWorker.format_ttl(90_000) == "01:30"
	end
end
