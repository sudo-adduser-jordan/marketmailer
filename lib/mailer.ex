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
	def init(state) do
		send_cheapest_order_email()
		schedule_tick()
		{:ok, state}
	end

	@impl true
	def handle_info(:tick, state) do
		send_cheapest_order_email()
		schedule_tick()
		{:noreply, state}
	end

	defp schedule_tick do
		Process.send_after(self(), :tick, @interval)
	end

	defp send_cheapest_order_email do
		case Database.cheapest_order() do
			nil ->
				Logger.debug("No orders available; skipping mail")

			order ->
				Logger.info("Sending mail for cheapest order #{order.order_id} at #{order.price}")
				deliver_email(order)
		end
	end

	defp deliver_email(order) do
		items = Database.get_items_less_than_jita_buy() |> Enum.take(100)
		template_path = Path.join(:code.priv_dir(:marketmailer), "lib/email.eex")
		html_content = EEx.eval_file(template_path, items: items)
		email = new_email(order, html_content)

		case Marketmailer.Mailer.deliver(email) do
			{:ok, response} ->
				Logger.info("Email sent successfully: #{inspect(response)}")

			{:error, reason} ->
				Logger.error("Failed to send email: #{inspect(reason)}")
		end
	end

	defp new_email(_order, html_content) do
		Swoosh.Email.new()
		|> Swoosh.Email.from("no-reply@resend.dev")
		|> Swoosh.Email.to(System.get_env("EMAIL"))
		|> Swoosh.Email.subject("Market Report")
		|> Swoosh.Email.html_body(html_content)
	end
end
