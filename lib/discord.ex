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
				respond(intr, Messages.channel_removed())

			"list_channel" ->
				chan_id =
					case Discord.Database.get(intr.guild_id) do
						%{channel_id: id} -> id
						_ -> nil
					end

				respond(intr, Messages.list_channel(chan_id))

			"check_market" ->
				Api.Interaction.create_response(intr, %{type: 5})
				items = Database.get_items_less_than_jita_buy() |> Enum.take(10)
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
		items = Database.get_items_less_than_jita_buy() |> Enum.take(10)

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
	end
end

defmodule Discord.Database do
	use Ecto.Schema

	@primary_key {:guild_id, :integer, autogenerate: false}

	schema "registered_channels" do
		field :channel_id, :integer
		timestamps()
	end

	def get(guild_id), do: Database.get(__MODULE__, guild_id)
	def all, do: Database.all(__MODULE__)

	def upsert(guild_id, channel_id) do
		%__MODULE__{guild_id: guild_id, channel_id: channel_id}
		|> Database.insert(on_conflict: [set: [channel_id: channel_id]], conflict_target: :guild_id)
	end

	def delete(guild_id) do
		case get(guild_id) do
			nil -> :ok
			struct -> Database.delete(struct)
		end
	end
end

defmodule Discord.Messages do
	alias Nostrum.Struct.Embed

	@color_success 0x43B581
	@color_error 0xF04747
	@color_info 0x7289DA

	# --- Base Wrappers ---

	def success(text), do: %Embed{description: "✅ #{text}", color: @color_success}
	def error(text), do: %Embed{description: "❌ #{text}", color: @color_error}

	# --- Command Specifics ---

	def channel_registered(id), do: success("<##{id}> is now registered for market alerts.")
	def channel_removed, do: success("Market alerts have been disabled for this server.")

	def list_channel(nil), do: error("No channel registered. Use `/add_channel` to start.")

	def list_channel(id) do
		%Embed{
			description: "📋 Monitoring alerts in <##{id}>",
			color: @color_info
		}
	end

	# --- Market Embed ---

	def market_embed([]), do: error("No items currently found below Jita Buy.")

	def market_embed(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy",
			color: @color_success,
			fields:
				Enum.map(items, fn i ->
					%{
						name: i.item,
						value: "💰 **B:** #{i.buy_price} | **S:** #{i.sell_price}\n📈 **Margin:** #{Float.round(i.margin * 100, 2)}%",
						inline: true
					}
				end),
			footer: %{text: "EVE Market Scan • #{DateTime.utc_now() |> DateTime.to_date()}"}
		}
	end
end
