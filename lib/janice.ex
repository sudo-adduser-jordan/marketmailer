defmodule Janice.Capture do
	@moduledoc """
	Provides an injectable boundary for capturing Janice market charts.
	"""

	@type result :: {:ok, binary()} | {:error, term()}
	@callback capture(pos_integer(), keyword()) :: result()

	def filename(type_id) when is_integer(type_id), do: "janice-#{type_id}.png"

	def fallback_filename, do: "janice-failed.png"

	def fallback_image do
		[__DIR__, "..", "assets", fallback_filename()] |> Path.join() |> Path.expand() |> File.read!()
	end

	def capture(type_id, opts \\ []) when is_integer(type_id) do
		adapter =
			Keyword.get(
				opts,
				:adapter,
				Application.get_env(:marketmailer, :janice_capture_adapter, Janice.Playwright)
			)

		adapter.capture(type_id, Keyword.delete(opts, :adapter))
	end
end

defmodule Janice.Supervisor do
	@moduledoc false
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
	@moduledoc false

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

		Marketmailer.Log.info(
			"janice_capture",
			%{type_id: type_id, elapsed_ms: System.monotonic_time(:millisecond) - started},
			"Janice capture finished"
		)

		result
	end

	# Fresh cached charts need no browser at all.
	defp cached_png(type_id) do
		ensure_cache()

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
		ensure_cache()
		:ets.insert(@cache_table, {type_id, png, System.monotonic_time(:millisecond)})
		:ok
	end

	defp ensure_cache do
		if :ets.whereis(@cache_table) == :undefined do
			:ets.new(@cache_table, [:named_table, :set, :public])
		end

		:ok
	end
end

defmodule Janice.ChartPool do
	@moduledoc false
	# One long-lived browser/context/page shared by every capture. Browser
	# launch (~seconds) used to be repaid per capture; now it happens once
	# and captures serialize through this process. A failed capture drops
	# the page (kept browser/context get a fresh page next time); a failed
	# page build drops everything for a full relaunch.
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

	# --- Page lifecycle ---

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
				{:error, reason} -> {:error, reason}
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

	# --- Capture ---

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
			nil -> {:error, :navigation_failed}
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
