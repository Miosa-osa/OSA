defmodule Canopy.Repo.Migrations.CreateAlertHistory do
  use Ecto.Migration

  def change do
    create table(:alert_history) do
      add :rule_id, references(:alert_rules, type: :binary_id, on_delete: :delete_all), null: false
      add :entity_value, :string
      add :resolved, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:alert_history, [:rule_id])
  end
end
