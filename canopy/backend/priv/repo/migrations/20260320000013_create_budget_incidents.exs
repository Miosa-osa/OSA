defmodule Canopy.Repo.Migrations.CreateBudgetIncidents do
  use Ecto.Migration

  def change do
    create table(:budget_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :policy_id, references(:budget_policies, type: :binary_id), null: false
      add :agent_id, references(:agents, type: :binary_id), null: false
      add :incident_type, :string, null: false
      add :threshold_pct, :integer, null: false
      add :actual_pct, :integer, null: false
      add :resolved, :boolean, null: false, default: false
      add :resolved_at, :utc_datetime
      add :resolved_by, references(:users, type: :binary_id)
      add :inserted_at, :utc_datetime, null: false
    end
  end
end
