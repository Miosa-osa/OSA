defmodule Canopy.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :binary_id)
      add :goal_id, references(:goals, type: :binary_id)
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "backlog"
      add :priority, :string, null: false, default: "medium"
      add :assignee_id, references(:agents, type: :binary_id)
      add :checked_out_by, references(:agents, type: :binary_id)
      timestamps()
    end

    create index(:issues, [:workspace_id])
    create index(:issues, [:status])
  end
end
