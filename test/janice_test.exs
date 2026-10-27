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
		assert is_binary(System.find_executable("playwright"))

		assert Code.ensure_loaded?(Janice.Playwright)
		assert Code.ensure_loaded?(Janice.Capture)

		assert function_exported?(Janice.Playwright, :capture, 2)
		assert function_exported?(Janice.Capture, :capture, 2)
	end

	test "browser is installed" do
		browsers =
			System.get_env("PLAYWRIGHT_BROWSERS_PATH") ||
				Path.join(System.user_home!(), ".cache/ms-playwright")

		assert File.dir?(browsers), "no playwright browser cache at #{browsers}"

		chromium =
			Path.join(browsers, "chromium-*/chrome-linux*/chrome")
			|> Path.wildcard()
			|> List.first()

		assert is_binary(chromium), "no chromium build installed under #{browsers}"
		assert File.exists?(chromium)
	end

	test "caputures item graph" do
		png = png_fixture(4, 3)

		assert {:ok, captured} =
						 Janice.Capture.capture(1_001,
							 adapter: Adapter,
							 result: {:ok, png},
							 test_pid: self()
						 )

		assert_receive {:captured, 1_001}
		assert is_binary(captured)
		assert {:ok, standard} = Janice.Padding.dimensions(captured)
		assert standard == Janice.Capture.image_size()
	end

	test "item graph is padded" do
		png = png_fixture(10, 6)

		assert Janice.Padding.default_pad() == 16
		assert {:ok, {10, 6}} = Janice.Padding.dimensions(png)

		assert {:ok, {42, 38}} = Janice.Padding.dimensions(Janice.Padding.pad(png))

		assert {:ok, small} =
						 Janice.Capture.capture(1_001,
							 adapter: Adapter,
							 result: {:ok, png},
							 test_pid: self(),
							 padding: 4
						 )

		{width, height} = Janice.Padding.chart_size()
		assert {:ok, {padded_width, padded_height}} = Janice.Padding.dimensions(small)
		assert padded_width == width + 8
		assert padded_height == height + 8
	end

	test "charts are normalised to the canonical size" do
		{width, height} = Janice.Padding.chart_size()

		for fixture <- [
					png_fixture(4, 3),
					png_fixture(width, height),
					png_fixture(width + 90, height),
					png_fixture(width, height + 40)
				] do
			assert {:ok, {^width, ^height}} = Janice.Padding.dimensions(Janice.Padding.fit(fixture))
		end

		exact = png_fixture(width, height)
		assert Janice.Padding.fit(exact) == exact
		assert Janice.Padding.fit("not a png") == "not a png"
	end

	test "caches exists" do
		assert Janice.Playwright.cache_table() == :janice_chart_cache
		assert :ets.whereis(:janice_chart_cache) != :undefined
		assert Janice.Playwright.cache_ttl_ms() == 3_600_000
	end

	test "caches graph image" do
		png = png_fixture(8, 8)
		:ets.insert(:janice_chart_cache, {1_001, png, System.monotonic_time(:millisecond)})

		assert {:ok, ^png} = Janice.Playwright.capture(1_001)
		assert [{1_001, ^png, inserted_at}] = :ets.lookup(:janice_chart_cache, 1_001)
		assert is_integer(inserted_at)
	end

	test "image size matches error and placeholder images" do
		assert {:ok, {width, height}} = Janice.Padding.dimensions(Janice.Capture.fallback_image())
		assert {width, height} == Janice.Capture.image_size()

		chart = png_fixture(800, 400)

		assert {:ok, {^width, ^height}} =
						 chart |> Janice.Padding.fit() |> Janice.Padding.pad() |> Janice.Padding.dimensions()

		assert {:ok, {^width, ^height}} =
						 File.read!("assets/background.png") |> Janice.Padding.dimensions()
	end

	test "missing playwright fallback" do
		message =
			"Executable doesn't exist at /root/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome\n" <>
				"run playwright install chromium"

		assert {:browser_missing, "/root/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome"} =
						 Janice.Playwright.classify_launch_error(%{error: %{message: message}})

		assert {:playwright_error, "boom"} =
						 Janice.Playwright.classify_launch_error(%{error: %{message: "boom\ntrace"}})

		assert Janice.Capture.fallback_filename() == "janice-failed.png"
		assert {:ok, {894, 400}} = Janice.Padding.dimensions(File.read!("assets/janice-failed.png"))
		assert {:ok, {926, 432}} = Janice.Padding.dimensions(Janice.Capture.fallback_image())
	end

	defp ensure_cache_table do
		case :ets.whereis(:janice_chart_cache) do
			:undefined -> :ets.new(:janice_chart_cache, [:named_table, :set, :public])
			_tid -> :ok
		end
	end

	defp png_fixture(width, height) do
		row = <<0>> <> :binary.copy(<<255, 0, 0>>, width)
		raw = :binary.copy(row, height)
		header = <<width::32-big, height::32-big, 8, 2, 0, 0, 0>>

		<<137, 80, 78, 71, 13, 10, 26, 10>> <>
			chunk("IHDR", header) <> chunk("IDAT", deflate(raw)) <> chunk("IEND", "")
	end

	defp chunk(type, data) do
		<<byte_size(data)::32-big, type::binary, data::binary, :erlang.crc32(type <> data)::32-big>>
	end

	defp deflate(raw) do
		z = :zlib.open()

		try do
			:ok = :zlib.deflateInit(z)
			out = :zlib.deflate(z, raw, :finish) |> IO.iodata_to_binary()
			:ok = :zlib.deflateEnd(z)
			out
		after
			:zlib.close(z)
		end
	end
end
