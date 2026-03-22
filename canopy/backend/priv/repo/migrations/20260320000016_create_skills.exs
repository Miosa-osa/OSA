defmodule Canopy.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :category, :string, null: false
      add :trigger_rules, :map, default: %{}
      add :enabled, :boolean, null: false, default: true
      timestamps()
    end
  end
end
