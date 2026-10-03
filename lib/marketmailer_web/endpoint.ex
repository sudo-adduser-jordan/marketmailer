defmodule MarketmailerWeb.Endpoint do
	@moduledoc """
	Minimal Phoenix endpoint exposing `Phoenix.LiveDashboard` for the ESI
	poller. No app routes — only `/dashboard` (see `MarketmailerWeb.Router`).

	Started under `Marketmailer.Application` when `:dashboard_enabled` is
	true (always except `config/test.exs`). Prod port/secret come from
	`config/runtime.exs` (`DASHBOARD_PORT` default 4000, `SECRET_KEY_BASE`);
	dev defaults live in `config/dev.exs` (`DASHBOARD_PORT` default 4001,
	isolated `priv/data/dev.db` via `task dev`).
	"""
	use Phoenix.Endpoint, otp_app: :marketmailer

	@session_options [
		store: :cookie,
		key: "_marketmailer_key",
		signing_salt: "marketmailer",
		same_site: "Lax"
	]

	socket "/live", Phoenix.LiveView.Socket,
		websocket: [connect_info: [session: @session_options]],
		longpoll: [connect_info: [session: @session_options]]

	plug Plug.RequestId
	plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

	plug Plug.Parsers,
		parsers: [:urlencoded, :multipart, :json],
		pass: ["*/*"],
		json_decoder: Phoenix.json_library()

	plug Plug.MethodOverride
	plug Plug.Head
	plug Plug.Session, @session_options
	plug MarketmailerWeb.Router
end
