defmodule DiscordBot do
	use Nostrum.Consumer

	alias Discord.Database
	alias Nostrum.Api
	alias Nostrum.Struct.Embed
	alias Nostrum.Struct.Interaction

	@admin_only "16"
	@interval 15 * 60 * 1000

	# --- Lifecycle ---

	def handle_event({:READY, _data, _ws_state}) do
		register_commands()
		schedule_broadcast()
	end

	# --- Recurring Logic ---

	def handle_info(:broadcast_market_updates, state) do
		items = Marketmailer.Database.get_items_less_than_jita_buy() |> Enum.take(10)

		if items != [] do
			embed = build_best_order_message(items)

			Marketmailer.Repo.all(Database)
			|> Enum.each(fn record ->
				Api.create_message(record.channel_id, embeds: [embed])
			end)
		end

		schedule_broadcast()
		{:noreply, state}
	end

	def handle_info(_msg, state), do: {:noreply, state}

	defp schedule_broadcast do
		Process.send_after(self(), :broadcast_market_updates, @interval)
	end

	# --- Interaction Handling ---

	def handle_event({:INTERACTION_CREATE, %Interaction{} = interaction, _ws_state}) do
		case interaction.data.name do
			"add_channel" ->
				Database.upsert(interaction.guild_id, interaction.channel_id)

				Api.create_interaction_response(interaction, %{
					type: 4,
					data: %{content: "✅ <##{interaction.channel_id}> registered for alerts."}
				})

			"remove_channel" ->
				Discord.Database.delete(interaction.guild_id)

				Api.create_interaction_response(interaction, %{
					type: 4,
					data: %{content: "🗑️ Market alerts disabled for this server."}
				})

			"list_channels" ->
				msg =
					case Marketmailer.Repo.get(Discord.Database, interaction.guild_id) do
						%{channel_id: chan_id} -> "📋 Monitoring channel: <##{chan_id}>"
						nil -> "❌ No channel registered."
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

	# --- Registration & Helpers ---

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

	import Ecto.Changeset
	import Ecto.Query

	alias Marketmailer.Repo

	@primary_key {:guild_id, :integer, autogenerate: false}
	schema "registered_channels" do
		field :channel_id, :integer
		timestamps()
	end

	@doc "Changeset for upserting channel records."
	def changeset(struct, params \\ %{}) do
		struct
		|> cast(params, [:guild_id, :channel_id])
		|> validate_required([:guild_id, :channel_id])
		|> unique_constraint(:guild_id)
	end

	@doc "Saves or updates a channel for a guild."
	def upsert(guild_id, channel_id) do
		%__MODULE__{guild_id: guild_id}
		|> changeset(%{channel_id: channel_id})
		|> Repo.insert(on_conflict: [set: [channel_id: channel_id]], conflict_target: :guild_id)
	end

	@doc "Removes a guild from the database."
	def delete(guild_id) do
		case Repo.get(__MODULE__, guild_id) do
			nil -> :ok
			struct -> Repo.delete(struct)
		end
	end
end

# defmodule Marketmailer.Repo.Migrations.CreateRegisteredChannels do
# 	use Ecto.Migration

# 	def change do
# 		create table(:registered_channels, primary_key: false) do
# 			add :guild_id, :bigint, primary_key: true
# 			add :channel_id, :bigint, null: false
# 			timestamps()
# 		end
# 	end
# end
