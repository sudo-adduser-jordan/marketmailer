defmodule MarketmailerWeb.ErrorHTML do
	@moduledoc false

	def render("404.html", _assigns), do: "Not Found"
	def render("500.html", _assigns), do: "Internal Server Error"
	def render(_template, _assigns), do: "Error"
end
