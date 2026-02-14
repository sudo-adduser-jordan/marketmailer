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
		deliver_email()
	end

	defp deliver_email do
		Logger.info("Fetching mail...")
		items = Database.get_items_less_than_jita_buy()
		# %{
		#   item: "Void S",
		#   buy_price: 35.01,
		#   sell_price: 35.0,
		#   margin: 0.00999999999999801
		# }

		Logger.info("Building mail...")
		template_path = Path.join(__DIR__, "email.eex")
		html_content = EEx.eval_file(template_path, items: items)
		email = new_email(html_content)

		case Marketmailer.Mailer.deliver(email) do
			{:ok, response} ->
				Logger.info("Email sent successfully: #{inspect(response)}")

			{:error, reason} ->
				Logger.error("Failed to send email: #{inspect(reason)}")
		end
	end

	defp new_email(html_content) do
		Swoosh.Email.new()
		|> Swoosh.Email.from("no-reply@resend.dev")
		|> Swoosh.Email.to(System.get_env("EMAIL"))
		|> Swoosh.Email.subject("Market Report")
		|> Swoosh.Email.html_body(html_content)
	end
end
