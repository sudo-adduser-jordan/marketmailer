defmodule MarketmailerWeb.DashboardAuth do
	@moduledoc """
	HTTP basic auth for `/dashboard` in prod.

	Inactive unless both `:dashboard_user` and `:dashboard_password` are
	configured (see `config/runtime.exs`: `DASHBOARD_USER` /
	`DASHBOARD_PASSWORD`). Dev stays open on localhost; test never boots
	the endpoint.
	"""
	import Plug.Conn

	def init(opts), do: opts

	def call(conn, _opts) do
		user = Application.get_env(:marketmailer, :dashboard_user)
		pass = Application.get_env(:marketmailer, :dashboard_password)

		if is_binary(user) and user != "" and is_binary(pass) and pass != "" do
			Plug.BasicAuth.basic_auth(conn, username: user, password: pass)
		else
			conn
		end
	end
end

defmodule MarketmailerWeb.Router do
	use Phoenix.Router

	import Phoenix.LiveDashboard.Router
	import Phoenix.LiveView.Router

	pipeline :browser do
		plug :accepts, ["html"]
		plug :fetch_session
		plug :fetch_live_flash
		plug :protect_from_forgery
		plug :put_secure_browser_headers
		plug MarketmailerWeb.DashboardAuth
	end

	scope "/" do
		pipe_through :browser

		live_dashboard "/dashboard",
			metrics: MarketmailerWeb.Telemetry,
			ecto_repos: [Database]
	end
end
