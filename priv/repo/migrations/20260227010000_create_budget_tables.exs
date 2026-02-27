defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateBudgetTables do
  use Ecto.Migration

  def change do
    create table(:budget_ledger) do
      add :timestamp, :utc_datetime_usec, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :tokens_in, :integer, null: false, default: 0
      add :tokens_out, :integer, null: false, default: 0
      add :cost_usd, :float, null: false, default: 0.0
      add :session_id, :string
      timestamps()
    end

    create index(:budget_ledger, [:session_id])
    create index(:budget_ledger, [:provider])
    create index(:budget_ledger, [:timestamp])

    create table(:budget_config) do
      add :daily_limit_usd, :float, null: false, default: 50.0
      add :monthly_limit_usd, :float, null: false, default: 500.0
      add :per_call_limit_usd, :float, null: false, default: 5.0
      timestamps()
    end
  end
end
