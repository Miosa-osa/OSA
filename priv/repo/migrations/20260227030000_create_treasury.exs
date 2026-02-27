defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateTreasury do
  use Ecto.Migration

  def change do
    create table(:treasury) do
      add :balance_usd, :float, default: 0.0
      add :reserved_usd, :float, default: 0.0
      add :daily_spent_usd, :float, default: 0.0
      add :daily_limit_usd, :float, default: 250.0
      add :monthly_spent_usd, :float, default: 0.0
      add :monthly_limit_usd, :float, default: 2500.0
      add :min_reserve_usd, :float, default: 10.0
      add :max_single_usd, :float, default: 50.0
      add :updated_at, :utc_datetime
    end

    create table(:treasury_transactions) do
      add :type, :string, null: false
      add :amount_usd, :float, null: false
      add :description, :string
      add :reference_id, :string
      add :balance_after, :float, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
