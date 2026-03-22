defmodule Canopy.Repo.Migrations.CreateBudgetPolicies do
  use Ecto.Migration

  def change do
    create table(:budget_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope_type, :string, null: false
      add :scope_id, :binary_id, null: false
      add :monthly_limit_cents, :integer, null: false
      add :warning_threshold_pct, :integer, null: false, default: 80
      add :hard_stop, :boolean, null: false, default: true
      timestamps()
    end

    create unique_index(:budget_policies, [:scope_type, :scope_id])
  end
end
