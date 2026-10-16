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

defmodule Janice.PaddingTest do
	use ExUnit.Case, async: true

	@pad 16

	test "pads the fallback chart with a white border" do
		raw = File.read!("assets/janice-failed.png")
		assert {:ok, {w, h}} = Janice.Padding.dimensions(raw)

		padded = Janice.Padding.pad(raw)
		assert {:ok, {w2, h2}} = Janice.Padding.dimensions(padded)
		assert {w2, h2} == {w + @pad * 2, h + @pad * 2}

		rows = filter_zero_rows!(padded, w2, h2, 3)
		assert length(rows) == h2
		assert hd(rows) == :binary.copy(<<255, 255, 255>>, w2)
		assert List.last(rows) == :binary.copy(<<255, 255, 255>>, w2)

		mid = Enum.at(rows, @pad)
		assert binary_part(mid, 0, @pad * 3) == :binary.copy(<<255>>, @pad * 3)
		assert binary_part(mid, byte_size(mid) - @pad * 3, @pad * 3) == :binary.copy(<<255>>, @pad * 3)
	end

	test "default pad is 16 white pixels" do
		assert Janice.Padding.default_pad() == 16
	end

	test "capture pads adapter PNGs and honors padding: 0" do
		raw = File.read!("assets/janice-failed.png")

		defmodule PadAdapter do
			def capture(_type_id, opts), do: Keyword.fetch!(opts, :result)
		end

		assert {:ok, padded} = Janice.Capture.capture(1_001, adapter: PadAdapter, result: {:ok, raw})
		assert {:ok, {w, h}} = Janice.Padding.dimensions(raw)
		assert {:ok, {w2, h2}} = Janice.Padding.dimensions(padded)
		assert {w2, h2} == {w + @pad * 2, h + @pad * 2}

		assert {:ok, ^raw} = Janice.Capture.capture(1_001, adapter: PadAdapter, result: {:ok, raw}, padding: 0)
	end

	test "fallback image ships padded" do
		raw = File.read!("assets/janice-failed.png")
		assert {:ok, {w, h}} = Janice.Padding.dimensions(raw)
		assert {:ok, {w2, h2}} = Janice.Capture.fallback_image() |> Janice.Padding.dimensions()
		assert {w2, h2} == {w + @pad * 2, h + @pad * 2}
	end

	test "leaves non-PNG and unsupported PNGs unchanged" do
		assert Janice.Padding.pad(<<1, 2, 3>>) == <<1, 2, 3>>
		assert Janice.Padding.pad("not a png") == "not a png"
		assert Janice.Padding.pad(nil) == nil
		assert :error = Janice.Padding.dimensions(<<1, 2, 3>>)

		deep = File.read!("assets/janice-failed.png") |> put_bit_depth(16)
		assert Janice.Padding.pad(deep) == deep
	end

	defp filter_zero_rows!(png, w, h, bpp) do
		<<_::binary-8, rest::binary>> = png
		idat = collect_idat!(rest)
		z = :zlib.open()

		try do
			:ok = :zlib.inflateInit(z)
			raw = :zlib.inflate(z, idat) |> IO.iodata_to_binary()
			:ok = :zlib.inflateEnd(z)
			stride = w * bpp
			rows = for <<0, row::binary-size(^stride) <- raw>>, do: row
			if length(rows) == h, do: rows, else: raise("unexpected row count")
		after
			:zlib.close(z)
		end
	end

	defp collect_idat!(rest), do: collect_idat!(rest, [])

	defp collect_idat!(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

	defp collect_idat!(<<len::32-big, "IDAT", data::binary-size(len), _crc::32-big, tail::binary>>, acc) do
		collect_idat!(tail, [data | acc])
	end

	defp collect_idat!(<<len::32-big, _type::binary-4, _data::binary-size(len), _crc::32-big, tail::binary>>, acc) do
		collect_idat!(tail, acc)
	end

	defp put_bit_depth(<<sig::binary-8, rest::binary>>, depth) do
		<<len::32-big, "IHDR", ihdr::binary-size(len), _crc::32-big, tail::binary>> = rest
		<<w::32-big, h::32-big, _old::8, color, comp, filter, interlace>> = ihdr
		new_hd = <<w::32-big, h::32-big, depth::8, color, comp, filter, interlace>>

		sig <>
			<<byte_size(new_hd)::32-big, "IHDR", new_hd::binary, :erlang.crc32("IHDR" <> new_hd)::32-big>> <> tail
	end
end
