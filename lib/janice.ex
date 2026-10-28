defmodule Janice.Padding do
	@signature <<137, 80, 78, 71, 13, 10, 26, 10>>
	@default_pad 16

	@chart_size {894, 400}

	def default_pad, do: @default_pad

	def chart_size, do: @chart_size

	def image_size do
		{width, height} = @chart_size
		{width + 2 * @default_pad, height + 2 * @default_pad}
	end

	def pad(png, pad \\ @default_pad)

	def pad(png, pad) when is_binary(png) and is_integer(pad) and pad > 0 do
		with {:ok, parts} <- parse(png),
				 {:ok, out} <- render(parts, pad) do
			out
		else
			_ -> png
		end
	end

	def pad(png, _pad) when is_binary(png), do: png
	def pad(other, _pad), do: other

	def fit(png, size \\ @chart_size)

	def fit(png, {width, height} = size)
			when is_binary(png) and is_integer(width) and width > 0 and is_integer(height) and height > 0 do
		case parse(png) do
			{:ok, parts} ->
				case parts do
					{_header, _others, _idat, ^width, ^height, _color, _bpp} -> png
					_ -> resize(png, parts, size)
				end

			_ ->
				png
		end
	end

	def fit(png, _size), do: png

	def dimensions(<<@signature, rest::binary>>) do
		with {:ok, header, _others, _idat} <- parse_chunks(rest, nil, [], []),
				 {:ok, {w, h, _color}, _bpp} <- pixel_info(header) do
			{:ok, {w, h}}
		else
			_ -> :error
		end
	end

	def dimensions(_), do: :error

	defp parse(<<@signature, rest::binary>>) do
		with {:ok, header, others, idat} <- parse_chunks(rest, nil, [], []),
				 {:ok, {w, h, color}, bpp} <- pixel_info(header) do
			{:ok, {header, others, idat, w, h, color, bpp}}
		else
			_ -> :error
		end
	end

	defp parse(_), do: :error

	defp parse_chunks(
				 <<len::32-big, type::binary-4, data::binary-size(len), _crc::32-big, rest::binary>>,
				 header,
				 others,
				 idats
			 ) do
		cond do
			type == "IHDR" -> parse_chunks(rest, data, others, idats)
			type == "IDAT" -> parse_chunks(rest, header, others, [data | idats])
			type == "IEND" -> {:ok, header, Enum.reverse(others), idats |> Enum.reverse() |> IO.iodata_to_binary()}
			true -> parse_chunks(rest, header, [{type, data} | others], idats)
		end
	end

	defp parse_chunks(_, _, _, _), do: :error

	defp pixel_info(<<w::32-big, h::32-big, 8, color, 0, 0, 0>>) when color in [0, 2, 6] and w > 0 and h > 0 do
		bpp = if color == 0, do: 1, else: if(color == 2, do: 3, else: 4)
		{:ok, {w, h, color}, bpp}
	end

	defp pixel_info(_), do: :error

	defp render({header, others, idat, w, h, color, bpp}, pad) do
		<<_old_w::32-big, _old_h::32-big, depth, _color, comp, filter, interlace>> = header

		with {:ok, rows} <- inflate_rows(idat, w, h, bpp),
				 {:ok, compressed} <- border_rows(rows, w, color, pad) |> deflate() do
			new_header = <<w + pad * 2::32-big, h + pad * 2::32-big, depth, color, comp, filter, interlace>>

			{:ok,
			 @signature <>
				 chunk("IHDR", new_header) <>
				 Enum.map_join(others, fn {type, data} -> chunk(type, data) end) <>
				 chunk("IDAT", compressed) <>
				 chunk("IEND", "")}
		else
			_ -> :error
		end
	end

	defp resize(png, {header, others, idat, w, h, color, bpp}, {width, height}) do
		<<_old_w::32-big, _old_h::32-big, depth, _color, comp, filter, interlace>> = header

		with {:ok, rows} <- inflate_rows(idat, w, h, bpp),
				 {:ok, compressed} <-
					 rows
					 |> fit_rows(w, width, height, color, bpp)
					 |> Enum.map(fn row -> [0, row] end)
					 |> deflate() do
			@signature <>
				chunk("IHDR", <<width::32-big, height::32-big, depth, color, comp, filter, interlace>>) <>
				Enum.map_join(others, fn {type, data} -> chunk(type, data) end) <>
				chunk("IDAT", compressed) <>
				chunk("IEND", "")
		else
			_ -> png
		end
	end

	defp chunk(type, data),
		do: <<byte_size(data)::32-big, type::binary, data::binary, :erlang.crc32(type <> data)::32-big>>

	defp inflate_rows(idat, w, h, bpp) do
		z = :zlib.open()

		try do
			:ok = :zlib.inflateInit(z)
			raw = :zlib.inflate(z, idat) |> IO.iodata_to_binary()
			:ok = :zlib.inflateEnd(z)
			unfilter_rows(raw, w, h, bpp)
		catch
			_, _ -> :error
		after
			:zlib.close(z)
		end
	end

	defp deflate(raw) do
		z = :zlib.open()

		try do
			:ok = :zlib.deflateInit(z)
			compressed = :zlib.deflate(z, raw, :finish) |> IO.iodata_to_binary()
			:ok = :zlib.deflateEnd(z)
			{:ok, compressed}
		catch
			_, _ -> :error
		after
			:zlib.close(z)
		end
	end

	defp unfilter_rows(raw, w, h, bpp) do
		stride = w * bpp
		unfilter_loop(raw, h, stride, bpp, :binary.copy(<<0>>, stride), [])
	end

	defp unfilter_loop(<<>>, 0, _stride, _bpp, _prev, acc), do: {:ok, Enum.reverse(acc)}

	defp unfilter_loop(<<f::8, rest::binary>>, n, stride, bpp, prev, acc) when f in 0..4 and n > 0 do
		case rest do
			<<scan::binary-size(^stride), tail::binary>> ->
				row = recon_row(f, scan, prev, bpp)
				unfilter_loop(tail, n - 1, stride, bpp, row, [row | acc])

			_ ->
				:error
		end
	end

	defp unfilter_loop(_, _, _, _, _, _), do: :error

	defp recon_row(f, scan, prev, bpp) do
		s = scan |> :binary.bin_to_list() |> List.to_tuple()
		p = prev |> :binary.bin_to_list() |> List.to_tuple()
		build_row(f, s, p, bpp, 1, tuple_size(s), [])
	end

	defp build_row(_f, _s, _p, _bpp, x, n, acc) when x > n, do: acc |> Enum.reverse() |> :binary.list_to_bin()

	defp build_row(f, s, p, bpp, x, n, acc) do
		sv = elem(s, x - 1)
		a = if x - bpp >= 1, do: Enum.at(acc, bpp - 1), else: 0
		b = elem(p, x - 1)
		c = if x - bpp >= 1, do: elem(p, x - bpp - 1), else: 0

		raw =
			case f do
				0 -> sv
				1 -> sv + a
				2 -> sv + b
				3 -> sv + div(a + b, 2)
				4 -> sv + paeth(a, b, c)
			end

		build_row(f, s, p, bpp, x + 1, n, [rem(raw, 256) | acc])
	end

	defp paeth(a, b, c) do
		p = a + b - c
		pa = abs(p - a)
		pb = abs(p - b)
		pc = abs(p - c)

		cond do
			pa <= pb and pa <= pc -> a
			pb <= pc -> b
			true -> c
		end
	end

	defp white_pixel(0), do: <<255>>
	defp white_pixel(2), do: <<255, 255, 255>>
	defp white_pixel(_), do: <<255, 255, 255, 255>>

	defp fit_rows(rows, w, width, height, color, bpp) do
		white_px = white_pixel(color)
		blank_row = :binary.copy(white_px, width)

		rows
		|> Enum.map(&fit_row(&1, w, width, bpp, white_px))
		|> center_slice(height, blank_row)
	end

	defp fit_row(row, w, width, _bpp, _white_px) when w == width, do: row

	defp fit_row(row, w, width, bpp, _white_px) when w > width do
		offset = div(w - width, 2) * bpp
		binary_part(row, offset, width * bpp)
	end

	defp fit_row(row, w, width, _bpp, white_px) do
		missing = width - w
		front = div(missing, 2)
		back = missing - front

		:binary.copy(white_px, front) <> row <> :binary.copy(white_px, back)
	end

	defp center_slice(items, count, filler) do
		actual = Kernel.length(items)

		cond do
			actual == count ->
				items

			actual > count ->
				drop = div(actual - count, 2)
				items |> Enum.drop(drop) |> Enum.take(count)

			true ->
				missing = count - actual
				front = div(missing, 2)
				back = missing - front
				List.duplicate(filler, front) ++ items ++ List.duplicate(filler, back)
		end
	end

	defp border_rows(rows, w, color, pad) do
		white_px = white_pixel(color)
		side = :binary.copy(white_px, pad)
		edge = [0, :binary.copy(white_px, w + pad * 2)]
		middle = Enum.map(rows, fn row -> [0, side, row, side] end)

		IO.iodata_to_binary(List.duplicate(edge, pad) ++ middle ++ List.duplicate(edge, pad))
	end
end

defmodule Janice.Capture do
	@type result :: {:ok, binary()} | {:error, term()}
	@callback capture(pos_integer(), keyword()) :: result()

	def filename(type_id) when is_integer(type_id), do: "janice-#{type_id}.png"

	def fallback_filename, do: "janice-failed.png"

	def fallback_image do
		png = [__DIR__, "..", "assets", fallback_filename()] |> Path.join() |> Path.expand() |> File.read!()
		png |> Janice.Padding.fit() |> Janice.Padding.pad()
	end

	def image_size, do: Janice.Padding.image_size()

	def capture(type_id, opts \\ []) when is_integer(type_id) do
		adapter =
			Keyword.get(
				opts,
				:adapter,
				Application.get_env(:marketmailer, :janice_capture_adapter, Janice.Playwright)
			)

		padding = Keyword.get(opts, :padding, Janice.Padding.default_pad())
		inner_opts = opts |> Keyword.drop([:adapter, :padding])

		case adapter.capture(type_id, inner_opts) do
			{:ok, png} -> {:ok, png |> Janice.Padding.fit() |> Janice.Padding.pad(padding)}
			other -> other
		end
	end
end

defmodule Janice.Supervisor do
	use Supervisor

	def start_link(opts \\ []) do
		previous_trap_exit = Process.flag(:trap_exit, true)

		try do
			case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
				{:ok, pid} -> {:ok, pid}
				{:error, reason} -> unavailable(reason)
			end
		catch
			:exit, reason -> unavailable(reason)
		after
			Process.flag(:trap_exit, previous_trap_exit)
		end
	end

	@impl true
	def init(opts) do
		executable = Keyword.get(opts, :executable, "playwright")
		connection_timeout = Keyword.get(opts, :connection_timeout, 5_000)

		children = [
			{PlaywrightEx.Supervisor, executable: executable, timeout: connection_timeout, name: PlaywrightEx.Supervisor},
			{Janice.ChartPool, []}
		]

		Supervisor.init(children, strategy: :one_for_one)
	end

	defp unavailable(reason) do
		Marketmailer.Log.warning(
			"janice_capture_disabled",
			%{reason: unavailable_reason(reason)},
			"Janice chart capture disabled; using the static market thumbnail"
		)

		:ignore
	end

	defp unavailable_reason({:shutdown, {:failed_to_start_child, _module, reason}}), do: unavailable_reason(reason)

	defp unavailable_reason({reason, _stacktrace}) when is_binary(reason), do: reason
	defp unavailable_reason({reason, _stacktrace}) when is_exception(reason), do: Exception.message(reason)
	defp unavailable_reason(reason) when is_exception(reason), do: Exception.message(reason)
	defp unavailable_reason(reason), do: inspect(reason)
end

defmodule Janice.Playwright do
	@behaviour Janice.Capture

	@default_timeout 20_000
	@call_margin_ms 10_000
	@cache_table :janice_chart_cache
	@cache_ttl_ms 3_600_000

	def cache_table, do: @cache_table
	def cache_ttl_ms, do: @cache_ttl_ms

	@impl true
	def capture(type_id, opts \\ []) do
		timeout = Keyword.get(opts, :timeout, @default_timeout)
		started = System.monotonic_time(:millisecond)

		result =
			case cached_png(type_id) do
				{:ok, png} -> {:ok, png}
				:miss -> pooled_capture(type_id, timeout)
			end

		log_browser_missing(result)

		Marketmailer.Log.info(
			"janice_capture",
			%{type_id: type_id, elapsed_ms: System.monotonic_time(:millisecond) - started},
			"Janice capture finished"
		)

		result
	end

	@browser_missing_marker "Executable doesn't exist at "

	def classify_launch_error(%{error: %{message: message}}) when is_binary(message) do
		case browser_missing_path(message) do
			path when is_binary(path) and path != "" -> {:browser_missing, path}
			_ -> {:playwright_error, first_line(message)}
		end
	end

	def classify_launch_error(reason), do: {:playwright_error, reason |> inspect() |> first_line()}

	defp browser_missing_path(message) do
		case String.split(message, @browser_missing_marker, parts: 2) do
			[_before, rest] -> rest |> String.split("\n", parts: 2) |> hd() |> String.trim()
			_ -> nil
		end
	end

	defp first_line(message) do
		message |> String.split("\n", parts: 2) |> hd() |> String.trim()
	end

	defp log_browser_missing({:error, {:browser_missing, path}}) do
		Marketmailer.Log.warning(
			"janice_browser_missing",
			%{expected_path: path, install_hint: "playwright install chromium"},
			"Playwright browser missing; run `playwright install chromium`"
		)
	end

	defp log_browser_missing(_result), do: :ok

	defp cached_png(type_id) do
		case :ets.lookup(@cache_table, type_id) do
			[{^type_id, png, inserted_at}] ->
				if System.monotonic_time(:millisecond) - inserted_at < @cache_ttl_ms do
					{:ok, png}
				else
					:miss
				end

			_ ->
				:miss
		end
	end

	defp pooled_capture(type_id, timeout) do
		cond do
			Process.whereis(PlaywrightEx.Supervisor) == nil ->
				{:error, :playwright_unavailable}

			Process.whereis(Janice.ChartPool) == nil ->
				{:error, :playwright_unavailable}

			true ->
				call_pool(type_id, timeout)
		end
	end

	defp call_pool(type_id, timeout) do
		case GenServer.call(Janice.ChartPool, {:capture, type_id, timeout}, timeout + @call_margin_ms) do
			{:ok, png} = ok ->
				store_png(type_id, png)
				ok

			other ->
				other
		end
	catch
		:exit, {:timeout, _} -> {:error, :capture_timeout}
		:exit, reason -> {:error, reason}
	end

	defp store_png(type_id, png) do
		:ets.insert(@cache_table, {type_id, png, System.monotonic_time(:millisecond)})
		:ok
	end
end

defmodule Janice.ChartPool do
	use GenServer

	alias PlaywrightEx.{Browser, BrowserContext, Frame, Page}

	@selector_timeout 8_000
	@cooldown_ms 60_000
	@cleanup_timeout 2_000

	def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init([]) do
		{:ok, %{browser: nil, context: nil, page: nil, down_since: nil}}
	end

	@impl true
	def handle_call({:capture, type_id, timeout}, _from, state) do
		url = "https://janice.e-351.com/i/#{type_id}/market/2"

		case ensure_page(state, timeout) do
			{:ok, page, state} ->
				case capture_on_page(page, url, timeout) do
					{:ok, _png} = ok -> {:reply, ok, state}
					{:error, _reason} = error -> {:reply, error, drop_page(state)}
				end

			{:error, reason, state} ->
				{:reply, {:error, reason}, state}
		end
	end

	defp ensure_page(%{page: page} = state, _timeout) when not is_nil(page), do: {:ok, page, state}

	defp ensure_page(%{down_since: since} = state, timeout) do
		if not is_nil(since) and System.monotonic_time(:millisecond) - since < @cooldown_ms do
			{:error, :browser_cooldown, state}
		else
			launch_all(%{state | down_since: nil}, timeout)
		end
	end

	defp launch_all(state, timeout) do
		case launch_browser(state, timeout) do
			{:ok, browser} ->
				case new_page(browser, state, timeout) do
					{:ok, context, page} ->
						{:ok, page, %{state | browser: browser, context: context, page: page, down_since: nil}}

					{:error, reason} ->
						{:error, reason, mark_down(state)}
				end

			{:error, reason} ->
				{:error, reason, mark_down(state)}
		end
	end

	defp launch_browser(%{browser: browser}, _timeout) when not is_nil(browser), do: {:ok, browser}

	defp launch_browser(_state, timeout) do
		if Process.whereis(PlaywrightEx.Supervisor) do
			case PlaywrightEx.launch_browser(:chromium, timeout: timeout) do
				{:ok, browser} -> {:ok, browser}
				{:error, reason} -> {:error, Janice.Playwright.classify_launch_error(reason)}
			end
		else
			{:error, :playwright_unavailable}
		end
	end

	defp new_page(browser, %{context: context} = _state, timeout) when not is_nil(context) do
		case BrowserContext.new_page(context.guid, timeout: timeout) do
			{:ok, page} -> {:ok, context, page}
			{:error, _reason} -> fresh_context(browser, timeout)
		end
	end

	defp new_page(browser, _state, timeout), do: fresh_context(browser, timeout)

	defp fresh_context(browser, timeout) do
		with {:ok, context} <- Browser.new_context(browser.guid, timeout: timeout),
				 {:ok, page} <- BrowserContext.new_page(context.guid, timeout: timeout) do
			{:ok, context, page}
		end
	end

	defp drop_page(state) do
		if state.page, do: close_quietly(fn -> Page.close(state.page.guid, timeout: @cleanup_timeout) end)
		%{state | page: nil}
	end

	defp mark_down(state) do
		%{state | browser: nil, context: nil, page: nil, down_since: System.monotonic_time(:millisecond)}
	end

	defp close_quietly(fun) do
		fun.()
	catch
		:exit, _ -> :ok
	end

	defp capture_on_page(page, url, timeout) do
		frame = page.main_frame

		with :ok <- navigate(frame, url, timeout),
				 :ok <- wait_chart(frame, timeout),
				 {:ok, encoded} <- screenshot(page, frame, timeout) do
			decode_png(encoded)
		end
	end

	defp navigate(frame, url, timeout) do
		case Frame.goto(frame.guid, url: url, wait_until: "domcontentloaded", timeout: timeout) do
			{:ok, _response} -> :ok
			{:error, reason} -> {:error, reason}
		end
	end

	defp wait_chart(frame, timeout) do
		case Frame.wait_for_selector(frame.guid, selector: "canvas", timeout: min(timeout, @selector_timeout)) do
			{:ok, _element} -> :ok
			{:error, reason} -> {:error, reason}
		end
	end

	defp screenshot(page, frame, timeout) do
		locator = %{frame: frame, selector: "canvas"}

		case Page.expect_screenshot(page.guid, timeout: timeout, locator: locator) do
			{:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
			{:ok, _} -> {:error, :empty_screenshot}
			{:error, reason} -> {:error, reason}
		end
	end

	defp decode_png(encoded) do
		case Base.decode64(encoded) do
			{:ok, png} when byte_size(png) > 0 -> {:ok, png}
			{:ok, _empty} -> {:error, :empty_screenshot}
			:error -> {:error, :invalid_screenshot_encoding}
		end
	end
end
