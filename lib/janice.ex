defmodule Janice.Capture do
	@moduledoc """
	Provides an injectable boundary for capturing Janice market charts.
	"""

	@type result :: {:ok, binary()} | {:error, term()}
	@callback capture(pos_integer(), keyword()) :: result()

	def filename(type_id) when is_integer(type_id), do: "janice-#{type_id}.png"

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
		executable = Keyword.get(opts, :executable, System.get_env("PLAYWRIGHT_EXECUTABLE", "playwright"))
		connection_timeout = Keyword.get(opts, :connection_timeout, 5_000)

		children = [
			{PlaywrightEx.Supervisor, executable: executable, timeout: connection_timeout, name: PlaywrightEx.Supervisor}
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

	alias PlaywrightEx.{Browser, BrowserContext, Frame, Page}

	@default_timeout 20_000
	@cleanup_timeout 2_000
	@chart_selectors [
		"canvas",
		"[class*='chart'] canvas",
		"[data-testid*='chart']",
		"[class*='graph'] canvas",
		"svg"
	]

	@impl true
	def capture(type_id, opts \\ []) do
		timeout = Keyword.get(opts, :timeout, @default_timeout)
		url = "https://janice.e-351.com/i/#{type_id}/market/2"

		with_browser(timeout, fn browser ->
			with_page(browser, timeout, fn page ->
				with :ok <- navigate(page, url, timeout),
						 {:ok, encoded} <- chart_screenshot(page, timeout) do
					decode_png(encoded)
				end
			end)
		end)
	end

	defp with_browser(timeout, fun) do
		if Process.whereis(PlaywrightEx.Supervisor) do
			case PlaywrightEx.launch_browser(:chromium, timeout: timeout) do
				{:ok, browser} ->
					try do
						fun.(browser)
					after
						close_browser(browser)
					end

				{:error, reason} ->
					{:error, reason}
			end
		else
			{:error, :playwright_unavailable}
		end
	end

	defp with_page(browser, timeout, fun) do
		case Browser.new_context(browser.guid, timeout: timeout) do
			{:ok, context} ->
				try do
					case BrowserContext.new_page(context.guid, timeout: timeout) do
						{:ok, page} ->
							try do
								fun.(page)
							after
								Page.close(page.guid, timeout: cleanup_timeout(timeout))
							end

						{:error, reason} ->
							{:error, reason}
					end
				after
					BrowserContext.close(context.guid, timeout: cleanup_timeout(timeout))
				end

			{:error, reason} ->
				{:error, reason}
		end
	end

	defp navigate(page, url, timeout) do
		case Frame.goto(page.main_frame,
					 url: url,
					 wait_until: "domcontentloaded",
					 timeout: timeout
				 ) do
			{:ok, _response} -> :ok
			{:error, reason} -> {:error, reason}
			nil -> {:error, :navigation_failed}
		end
	end

	defp chart_screenshot(page, timeout) do
		Enum.reduce_while(@chart_selectors, {:error, :chart_not_found}, fn selector, acc ->
			locator = %{frame: page.main_frame, selector: selector}

			case Page.expect_screenshot(page.guid,
						 timeout: timeout,
						 expected: nil,
						 locator: locator
					 ) do
				{:ok, encoded} when is_binary(encoded) -> {:halt, {:ok, encoded}}
				{:error, _reason} -> {:cont, acc}
			end
		end)
	end

	defp decode_png(encoded) do
		case Base.decode64(encoded) do
			{:ok, png} when byte_size(png) > 0 -> {:ok, png}
			{:ok, _empty} -> {:error, :empty_screenshot}
			:error -> {:error, :invalid_screenshot_encoding}
		end
	end

	defp close_browser(browser) do
		Browser.close(browser.guid, timeout: @cleanup_timeout)
	catch
		:exit, _reason -> :ok
	end

	defp cleanup_timeout(timeout) when is_integer(timeout), do: min(timeout, @cleanup_timeout)
	defp cleanup_timeout(_timeout), do: @cleanup_timeout
end
