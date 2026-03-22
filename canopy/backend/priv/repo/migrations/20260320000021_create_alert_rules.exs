defmodule Canopy.Repo.Migrations.CreateAlertRules do
  use Ecto.Migration

  def change do
    create table(:alert_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :entity, :string, null: false
      add :field, :string, null: false
      add :operator, :string, null: false
      add :value, :string, null: false
      add :cooldown_minutes, :integer, null: false, default: 60
      add :notify_targets, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :trigger_count, :integer, null: false, default: 0
      add :last_triggered_at, :utc_datetime
      timestamps()
    end
  end
end
