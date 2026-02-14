defmodule ExampleConsumer do
	@behaviour Nostrum.Consumer

	alias Nostrum.Api.Message

	def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
		case msg.content do
			"ping!" ->
				Message.create(msg.channel_id, "I copy and pasted this code")

			_ ->
				:ignore
		end
	end
end
