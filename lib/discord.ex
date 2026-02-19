defmodule Discord.Messages do
	alias Nostrum.Struct.Embed

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	def channel_registered(id) do
		%Embed{description: "✅ Channel <##{id}> is now registered for market alerts.", color: @color_success}
	end

	def channel_removed(id) do
		%Embed{description: "🗑️ Market alerts have been disabled for Channel <##{id}>.", color: @color_error}
	end

	def list_channel(nil),
		do: %Embed{description: "❌ Error: No channel registered. Use `/add_channel` to start.", color: @color_error}

	def list_channel(id) do
		%Embed{
			description: "📋 Monitoring alerts in <##{id}>",
			color: @color_info
		}
	end

	def market_embed([]), do: %Embed{description: "❌ Error: Unable to check market database.", color: @color_error}

	def market_embed(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy",
			color: @color_success,
			fields:
				Enum.map(items, fn item ->
					%{
						name: item.item,
						value:
							"💰 **B:** #{item.buy_price} | **S:** #{item.sell_price}\n📈 **Margin:** #{Float.round(item.margin * 100, 2)}%",
						inline: true
					}
				end),
			footer: %{text: "EVE Market Scan • #{DateTime.utc_now() |> DateTime.to_date()}"}
		}
	end
end

defmodule Discord.Consumer do
	@behaviour Nostrum.Consumer

	alias Discord.Messages
	alias Nostrum.Api
	alias Nostrum.Struct.Interaction

	@admin_only "16"
	@interval 15 * 60 * 1000

	def handle_event({:READY, _, _}),
		do:
			(
				register_commands()
				schedule_broadcast()
			)

	def handle_event({:INTERACTION_CREATE, %Interaction{data: %{name: name}} = intr, _}) do
		case name do
			"add_channel" ->
				# Discord.Database.upsert(intr.guild_id, intr.channel_id)
				respond(intr, Messages.channel_registered(intr.channel_id))

			"remove_channel" ->
				# Discord.Database.delete(intr.guild_id)
				respond(intr, Messages.channel_removed(intr.channel_id))

			"list_channel" ->
				case Discord.Database.get(intr.guild_id) do
					%{channel_id: id} ->
						respond(intr, Messages.list_channel(id))

					_ ->
						respond(intr, Messages.list_channel(nil))
				end

			"check_market" ->
				Api.Interaction.create_response(intr, %{type: 5})
				items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)
				Api.Interaction.edit_response(intr, %{embeds: [Messages.market_embed(items)]})
		end
	end

	def handle_event(_), do: :ok

	# --- Helpers ---

	defp respond(intr, %Nostrum.Struct.Embed{} = embed) do
		Api.Interaction.create_response(intr, %{
			type: 4,
			data: %{embeds: [embed]}
		})
	end

	def handle_info(:broadcast, state) do
		items = Market.Database.get_items_less_than_jita_buy() |> Enum.take(10)

		if items != [] do
			embed = Messages.market_embed(items)

			Enum.each(Discord.Database.all(), fn record ->
				Api.Message.create(record.channel_id, embeds: [embed])
			end)
		end

		schedule_broadcast()
		{:noreply, state}
	end

	defp schedule_broadcast, do: Process.send_after(self(), :broadcast, @interval)

	defp register_commands do
		commands = [
			%{name: "add_channel", description: "Set current channel for alerts", default_member_permissions: @admin_only},
			%{name: "remove_channel", description: "Remove alerts from this server", default_member_permissions: @admin_only},
			%{name: "list_channel", description: "Show the current update channel"},
			%{name: "check_market", description: "Scan the market immediately"}
		]

		Api.ApplicationCommand.bulk_overwrite_global_commands(commands)
		:ok
	end
end
