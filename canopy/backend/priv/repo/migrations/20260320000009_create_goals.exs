defmodule Canopy.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :binary_id)
      add :parent_id, references(:goals, type: :binary_id)
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      timestamps()
    end
  end
end
