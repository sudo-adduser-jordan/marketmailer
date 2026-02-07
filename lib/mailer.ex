defmodule Marketmailer.Mailer do
	@moduledoc false
	use Swoosh.Mailer, otp_app: :marketmailer
end

defmodule Marketmailer.MailWorker do
	@moduledoc false
	use GenServer

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
			# |> Swoosh.Email.html_body("<strong>Hello</strong>")
			|> Swoosh.Email.text_body("""
			Cheapest order:

			Order ID: #{order.order_id}
			Price: #{order.price}
			Type ID: #{order.type_id}
			Volume: #{order.volume_remain}/#{order.volume_total}
			Location: #{order.location_id}
			""")

		case Marketmailer.Mailer.deliver(email) do
			{:ok, response} ->
				Logger.info("Email sent successfully: #{inspect(response)}")

			{:error, reason} ->
				Logger.error("Failed to send email: #{inspect(reason)}")
		end
	end
end
