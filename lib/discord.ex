defmodule Discord.Consumer do
	@behaviour Nostrum.Consumer

	alias Nostrum.Api
	alias Nostrum.Struct.Embed
	alias Nostrum.Struct.Interaction

	@admin_only "16"
	@interval 15 * 60 * 1000

	# --- Lifecycle & Events ---

	def handle_event({:READY, _data, _ws_state}) do
		register_commands()
		schedule_broadcast()
	end

	def handle_event({:INTERACTION_CREATE, %Interaction{} = interaction, _ws_state}) do
		case interaction.data.name do
			"add_channel" ->
				[subcommand] = interaction.data.options

				case subcommand.name do
					"subcommand" ->
						option = Enum.find(subcommand.options, fn opt -> opt.name == "required_option" end)
						value = option.value

						Api.Interaction.create_response(interaction, %{
							type: 4,
							data: %{content: "✅ <##{interaction.channel_id}> registered for alerts."}
						})

						Discord.Database.upsert(interaction.guild_id, interaction.channel_id)
				end

			"remove_channel" ->
				[subcommand] = interaction.data.options

				case subcommand.name do
					"subcommand" ->
						option = Enum.find(subcommand.options, fn opt -> opt.name == "required_option" end)
						value = option.value

						Api.Interaction.create_response(interaction, %{
							type: 4,
							data: %{content: "🗑️ Market alerts disabled for this server."}
						})

						Discord.Database.delete(interaction.guild_id)
				end

			"list_channels" ->
				msg =
					case Discord.Database.get(interaction.guild_id) do
						%{channel_id: chan_id} -> "📋 Monitoring channel: <##{chan_id}>"
						nil -> "❌ No channel registered."
					end

				Api.Interaction.create_response(interaction, %{
					type: 4,
					data: %{content: msg}
				})

			"check_market" ->
				Api.Interaction.create_response(interaction, %{type: 5})

				items =
					Database.get_items_less_than_jita_buy()
					|> Enum.take(10)

				Api.Interaction.edit_response(interaction, %{
					embeds: [build_best_order_message(items)]
				})

			_ ->
				:ok
		end
	end

	def handle_event(_event), do: :ok

	# --- Recurring Logic ---

	def handle_info(:broadcast_market_updates, state) do
		items =
			Database.get_items_less_than_jita_buy()
			|> Enum.take(10)

		if items != [] do
			embed = build_best_order_message(items)

			Discord.Database.all()
			|> Enum.each(fn record ->
				Api.Message.create(record.channel_id, embeds: [embed])
			end)
		end

		schedule_broadcast()
		{:noreply, state}
	end

	def handle_info(_msg, state), do: {:noreply, state}

	defp schedule_broadcast do
		Process.send_after(self(), :broadcast_market_updates, @interval)
	end

	# --- Registration & Helpers ---

	defp register_commands do
		commands = [
			%{
				name: "add_channel",
				description: "Set the current channel for market updates",
				default_member_permissions: @admin_only,
				dm_permission: false,
				options: [
					%{
						type: 1,
						name: "subcommand",
						description: "Subcommand description",
						options: [
							%{
								type: 3,
								name: "required_option",
								description: "Description of your option",
								required: true
							}
						]
					}
				]
			},
			%{
				name: "remove_channel",
				description: "Stop market updates for this server",
				default_member_permissions: @admin_only,
				dm_permission: false,
				options: [
					%{
						type: 1,
						name: "subcommand",
						description: "Subcommand description",
						options: [
							%{
								type: 3,
								name: "required_option",
								description: "Description of your option",
								required: true
							}
						]
					}
				]
			},
			%{
				name: "list_channels",
				description: "Show the registered update channel",
				dm_permission: false
			},
			%{
				name: "check_market",
				description: "Manually scan for Jita deals"
			}
		]

		Api.ApplicationCommand.bulk_overwrite_global_commands(commands)
	end

	def build_best_order_message(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy Price",
			color: 0x00FF00,
			fields:
				Enum.map(items, fn item ->
					%{
						name: item.item,
						value:
							"**Buy:** #{format_price(item.buy_price)}\n" <>
								"**Sell:** #{format_price(item.sell_price)}\n" <>
								"**Margin:** #{format_margin(item.margin)}",
						inline: true
					}
				end),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
		}
	end

	defp format_price(p), do: :erlang.float_to_binary(p, decimals: 2) <> " ISK"
	defp format_margin(m), do: :erlang.float_to_binary(m * 100, decimals: 2) <> "%"
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
