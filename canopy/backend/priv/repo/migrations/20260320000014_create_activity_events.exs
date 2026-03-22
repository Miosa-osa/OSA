defmodule Canopy.Repo.Migrations.CreateActivityEvents do
  use Ecto.Migration

  def change do
    create table(:activity_events) do
      add :workspace_id, references(:workspaces, type: :binary_id), null: false
      add :event_type, :string, null: false
      add :agent_id, references(:agents, type: :binary_id)
      add :message, :text, null: false
      add :metadata, :map, default: %{}
      add :level, :string, null: false, default: "info"
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:activity_events, [:workspace_id])
    create index(:activity_events, [:event_type])
  end
end
