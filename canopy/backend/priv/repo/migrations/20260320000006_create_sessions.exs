defmodule Canopy.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :schedule_id, references(:schedules, type: :binary_id)
      add :model, :string, null: false
      add :status, :string, null: false, default: "active"
      add :tokens_input, :integer, default: 0
      add :tokens_output, :integer, default: 0
      add :tokens_cache, :integer, default: 0
      add :cost_cents, :integer, default: 0
      add :workspace_path, :string
      add :workspace_branch, :string
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      timestamps()
    end
  end
end
