defmodule Database.Migrations.AddContracts do
	use Ecto.Migration

	def change do
		create table(:contracts, primary_key: false) do
			add :contract_id, :bigint, primary_key: true
			add :region_id, :integer, null: false
			add :page, :integer, null: false
			add :type, :string
			add :title, :string
			add :price, :float
			add :buyout, :float
			add :reward, :float
			add :collateral, :float
			add :volume, :float
			add :expires_at, :bigint
			add :issued_at, :bigint
			add :days_to_complete, :integer
			add :start_location_id, :bigint
			add :end_location_id, :bigint
			add :issuer_id, :bigint
			add :issuer_corporation_id, :bigint
			add :items_fetched, :boolean, null: false, default: false
			add :items_attempts, :integer, null: false, default: 0
			add :items_next_attempt_at, :bigint, null: false, default: 0
			add :items_claim_round, :integer, null: false, default: 0
			add :last_seen_round, :integer, null: false, default: 0
			timestamps()
		end

		create index(:contracts, [:region_id, :page])
		create index(:contracts, [:items_fetched, :items_next_attempt_at, :expires_at])
		create index(:contracts, [:last_seen_round, :expires_at])
		create index(:contracts, [:price])

		create table(:contract_items, primary_key: false) do
			add :record_id, :bigint, primary_key: true
			add :contract_id, :bigint, primary_key: true
			add :type_id, :integer, null: false
			add :quantity, :integer
			add :is_included, :boolean
			add :is_blueprint_copy, :boolean
		end

		create index(:contract_items, [:contract_id])
		create index(:contract_items, [:type_id])
	end
end
