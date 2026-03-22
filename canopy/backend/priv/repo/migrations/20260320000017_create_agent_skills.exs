defmodule Canopy.Repo.Migrations.CreateAgentSkills do
  use Ecto.Migration

  def change do
    create table(:agent_skills, primary_key: false) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :skill_id, references(:skills, type: :binary_id, on_delete: :delete_all), null: false
      add :enabled, :boolean, null: false, default: true
    end

    create unique_index(:agent_skills, [:agent_id, :skill_id])
  end
end
