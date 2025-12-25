defmodule Marketmailer.Mailer do
  use Swoosh.Mailer, otp_app: :marketmailer
end

defmodule Marketmailer.Email do
  import Swoosh.Email

  def welcome(user) do
    new()
    |> to({user.name, user.email})
    |> from({"test from", "lostcoastwizard@gmail.com"})
    |> subject("test subject")
    |> html_body("<h1>html body : #{user.name}</h1>")
    |> text_body("text body : #{user.name}\n")
  end
end
