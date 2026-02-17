defmodule DiscordBot do
	use Nostrum.Consumer

	alias Nostrum.Api
	alias Nostrum.Struct.Embed
	alias Nostrum.Struct.Interaction

	@admin_only "16"
	# 15 Minutes in milliseconds
	@interval 15 * 60 * 1000

	# --- Lifecycle ---

	def handle_event({:READY, _data, _ws_state}) do
		if :ets.whereis(:guild_channels) == :undefined do
			:ets.new(:guild_channels, [:set, :public, :named_table])
		end

		register_commands()

		# Start the 15-minute loop
		schedule_broadcast()
	end

	# --- Recurring Logic ---

	def handle_info(:broadcast_market_updates, state) do
		# 1. Fetch the data once
		items = Database.get_items_less_than_jita_buy() |> Enum.take(10)

		if items != [] do
			embed = build_best_order_message(items)

			# 2. Iterate through all cached channels in ETS
			# ETS stores tuples as {guild_id, channel_id}
			:ets.tab2list(:guild_channels)
			|> Enum.each(fn {_guild_id, channel_id} ->
				Api.create_message(channel_id, embeds: [embed])
			end)
		end

		# 3. Reschedule
		schedule_broadcast()
		{:noreply, state}
	end

	# Catch-all for other info messages
	def handle_info(_msg, state), do: {:noreply, state}

	defp schedule_broadcast do
		Process.send_after(self(), :broadcast_market_updates, @interval)
	end

	# --- Interaction Handling ---

	def handle_event({:INTERACTION_CREATE, %Interaction{} = interaction, _ws_state}) do
		case interaction.data.name do
			"add_channel" ->
				:ets.insert(:guild_channels, {interaction.guild_id, interaction.channel_id})
				# Note: You should also persist this to your DB here

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
				items = Database.get_items_less_than_jita_buy() |> Enum.take(10)
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
			%{name: "list_channels", description: "Show the registered update channel", dm_permission: false},
			%{name: "check_market", description: "Manually scan for Jita deals"}
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
							"**Buy:** #{format_price(item.buy_price)}\n**Sell:** #{format_price(item.sell_price)}\n**Margin:** #{format_margin(item.margin)}",
						inline: true
					}
				end),
			timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
		}
	end

	defp format_price(p), do: :erlang.float_to_binary(p, decimals: 2) <> " ISK"
	defp format_margin(m), do: :erlang.float_to_binary(m * 100, decimals: 2) <> "%"
end

# defmodule Marketmailer.Repo.Migrations.CreateRegisteredChannels do
#   use Ecto.Migration

#   def change do
#     create table(:registered_channels, primary_key: false) do
#       # Discord IDs are large integers, stored as :bigint
#       add :guild_id, :bigint, primary_key: true
#       add :channel_id, :bigint, null: false

#       timestamps()
#     end
#   end
# end

# defmodule Discord.Database do
# 	use Ecto.Schema

# 	import Ecto.Changeset
# 	import Ecto.Query

# 	alias Marketmailer.Repo

# 	@primary_key {:guild_id, :integer, autogenerate: false}
# 	schema "registered_channels" do
# 		field :channel_id, :integer
# 		timestamps()
# 	end

# 	@doc "Changeset for upserting channel records."
# 	def changeset(struct, params \\ %{}) do
# 		struct
# 		|> cast(params, [:guild_id, :channel_id])
# 		|> validate_required([:guild_id, :channel_id])
# 		|> unique_constraint(:guild_id)
# 	end

# 	# --- Database Functions ---

# 	@doc "Saves or updates a channel for a guild."
# 	def upsert(guild_id, channel_id) do
# 		%__MODULE__{guild_id: guild_id}
# 		|> changeset(%{channel_id: channel_id})
# 		|> Repo.insert(on_conflict: [set: [channel_id: channel_id]], conflict_target: :guild_id)
# 	end

# 	@doc "Removes a guild from the database."
# 	def delete(guild_id) do
# 		case Repo.get(__MODULE__, guild_id) do
# 			nil -> :ok
# 			struct -> Repo.delete(struct)
# 		end
# 	end

# 	@doc "Loads all records into the ETS cache."
# 	def hydrate_cache(table_name) do
# 		__MODULE__
# 		|> Repo.all()
# 		|> Enum.each(fn %{guild_id: g, channel_id: c} ->
# 			:ets.insert(table_name, {g, c})
# 		end)
# 	end
# end
