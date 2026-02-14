defmodule Marketmailer.Mailer do
	use Swoosh.Mailer, otp_app: :marketmailer
end

defmodule Marketmailer.MailWorker do
	use GenServer

	alias Marketmailer.Database

	require Logger

	@interval to_timeout(minute: 1)

	def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

	@impl true
	def init(_) do
		send_cheapest_order_email()
		schedule_tick()
		{:ok, %{}}
	end

	@impl true
	def handle_info(:tick, state) do
		# send_cheapest_order_email()
		schedule_tick()
		{:noreply, state}
	end

	defp schedule_tick do
		Process.send_after(self(), :tick, @interval)
	end

	defp send_cheapest_order_email do
		case Marketmailer.Database.cheapest_order() do
			nil ->
				Logger.debug("No orders available; skipping mail")

			order ->
				Logger.info("Sending mail for cheapest order #{order.order_id} at #{order.price}")
				deliver_email(order)
		end
	end

	defp deliver_email(order) do
		email =
			Swoosh.Email.new()
			|> Swoosh.Email.from("no-reply@resend.dev")
			|> Swoosh.Email.to(System.get_env("EMAIL"))
			|> Swoosh.Email.subject("marketmailer")
			|> Swoosh.Email.html_body("""
			<html>
				<head>
					<style>
						body {
							font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
							background-color: #f4f4f5;
							padding: 24px;
							color: #111827;
						}

						.container {
							max-width: 480px;
							margin: 0 auto;
							background-color: #ffffff;
							border-radius: 8px;
							padding: 20px 24px;
							box-shadow: 0 10px 15px -3px rgba(0,0,0,0.1),
													0 4px 6px -4px rgba(0,0,0,0.1);
						}

						h1 {
							font-size: 20px;
							margin-bottom: 16px;
						}

						.order-row {
							margin-bottom: 6px;
							font-size: 14px;
						}

						.label {
							font-weight: 600;
							color: #4b5563;
						}

						.value {
							color: #111827;
						}
					</style>
				</head>
				<body>
					<div class="container">
						<h1>Cheapest order</h1>

						<div class="order-row">
							<span class="label">Order ID:</span>
							<span class="value">#{order.order_id}</span>
						</div>

						<div class="order-row">
							<span class="label">Price:</span>
							<span class="value">#{order.price}</span>
						</div>

						<div class="order-row">
							<span class="label">Type ID:</span>
							<span class="value">#{order.type_id}</span>
						</div>

						<div class="order-row">
							<span class="label">Volume:</span>
							<span class="value">#{order.volume_remain}/#{order.volume_total}</span>
						</div>

						<div class="order-row">
							<span class="label">Location:</span>
							<span class="value">#{order.location_id}</span>
						</div>
					</div>
				</body>
			</html>
			""")

		case Marketmailer.Mailer.deliver(email) do
			{:ok, response} ->
				Logger.info("Email sent successfully: #{inspect(response)}")

			{:error, reason} ->
				Logger.error("Failed to send email: #{inspect(reason)}")
		end

		# Database.get_items_less_than_jita_buy()
	end
end
