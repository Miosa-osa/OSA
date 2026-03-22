defmodule Canopy.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :cron_expression, :string, null: false
      add :context, :text
      add :enabled, :boolean, null: false, default: true
      add :timezone, :string, default: "UTC"
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime
      add :last_run_status, :string
      timestamps()
    end
  end
end
