defmodule DiscordBot do
	use Nostrum.Consumer

	alias Nostrum.Api
	alias Nostrum.Struct.Embed
	alias Nostrum.Struct.Interaction

	@admin_only "16"

	def handle_event({:READY, _data, _ws_state}) do
		if :ets.whereis(:guild_channels) == :undefined do
			:ets.new(:guild_channels, [:set, :public, :named_table])
		end

		register_commands()
	end

	def handle_event({:INTERACTION_CREATE, %Interaction{} = interaction, _ws_state}) do
		case interaction.data.name do
			"add_channel" ->
				:ets.insert(:guild_channels, {interaction.guild_id, interaction.channel_id})

				Api.create_interaction_response(interaction, %{
					type: 4,
					data: %{content: "✅ <##{interaction.channel_id}> registered for alerts."}
				})

			"remove_channel" ->
				:ets.delete(:guild_channels, interaction.guild_id)

				Api.create_interaction_response(interaction, %{
					type: 4,
					data: %{content: "🗑️ Market alerts disabled for this server."}
				})

			"list_channels" ->
				msg =
					case :ets.lookup(:guild_channels, interaction.guild_id) do
						[{_guild, chan}] -> "📋 Monitoring channel: <##{chan}>"
						[] -> "❌ No channel registered."
					end

				Api.create_interaction_response(interaction, %{
					type: 4,
					data: %{content: msg}
				})

			"check_market" ->
				Api.create_interaction_response(interaction, %{type: 5})
				items = Marketmailer.Database.get_items_less_than_jita_buy() |> Enum.take(10)
				Api.edit_interaction_response(interaction, %{embeds: [build_best_order_message(items)]})

			_ ->
				:ok
		end
	end

	def handle_event(_event), do: :ok

	# --- Registration ---

	defp register_commands do
		commands = [
			%{
				name: "add_channel",
				description: "Set the current channel for market updates",
				default_member_permissions: @admin_only,
				dm_permission: false
			},
			%{
				name: "remove_channel",
				description: "Stop market updates for this server",
				default_member_permissions: @admin_only,
				dm_permission: false
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

		Api.bulk_overwrite_global_commands(commands)
	end

	# --- Helpers ---

	def build_best_order_message(items) do
		%Embed{
			title: "🛒 Items Below Jita Buy Price",
			color: 0x00FF00,
			fields:
				Enum.map(items, fn item ->
					%{
						name: item.item,
						value:
							"**Buy:** #{format_price(item.buy_price)}\n**Sell:** #{format_price(item.sell_price)}\n**Margin:** #{format_margin(item.margin)}",
						inline: true
					}
				end)
		}
	end

	defp format_price(p), do: :erlang.float_to_binary(p, decimals: 2) <> " ISK"
	defp format_margin(m), do: :erlang.float_to_binary(m * 100, decimals: 2) <> "%"
end
