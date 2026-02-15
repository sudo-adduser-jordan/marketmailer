defmodule DiscordBot do
	use GenServer

	alias Nostrum.Api, as: API
	alias Nostrum.Struct.Embed

	def start_link(_opts) do
		GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
	end

	def init(state) do
		send_discord_message()
		schedule_message()
		{:ok, state}
	end

	def handle_info(:check_items, state) do
		send_discord_message()
		schedule_message()
		{:noreply, state}
	end

	defp schedule_message do
		Process.send_after(self(), :check_items, 30 * 60 * 1000)
	end

	defp send_discord_message do
		items = Marketmailer.Database.get_items_less_than_jita_buy() |> Enum.take(10)

		if items != [] do
			embed = build_best_order_message(items)
			# embed = build_top_100_message(items)
			API.create_message!(YOUR_CHANNEL_ID, embed: embed)
		end
	end

	def build_best_order_message(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy Price",
			# Green
			color: 0x00FF00,
			fields:
				Enum.map(items, fn item ->
					%{
						name: item.item,
						value: """
						**Buy:** #{item.buy_price |> format_price()}
						**Sell:** #{item.sell_price |> format_price()}
						**Margin:** #{format_margin(item.margin)}
						""",
						inline: true
					}
				end),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
		}
	end

	def build_top_100_message(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy Price",
			# Green
			color: 0x00FF00,
			fields:
				Enum.map(items, fn item ->
					%{
						name: item.item,
						value: """
						**Buy:** #{item.buy_price |> format_price()}
						**Sell:** #{item.sell_price |> format_price()}
						**Margin:** #{format_margin(item.margin)}
						""",
						inline: true
					}
				end),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
		}
	end

	defp format_price(price) do
		:io_lib.format("~.2f ISK", [price])
		|> to_string()
	end

	defp format_margin(margin) do
		pct = margin * 100

		:io_lib.format("~.2f%", [pct])
		|> to_string()
	end
end
