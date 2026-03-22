defmodule Canopy.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :role, :string, null: false
      add :reports_to, references(:agents, type: :binary_id)
      add :adapter, :string, null: false
      add :model, :string, null: false
      add :temperature, :float, default: 0.3
      add :max_concurrent_runs, :integer, default: 1
      add :status, :string, null: false, default: "sleeping"
      add :config, :map, default: %{}
      add :system_prompt, :text
      timestamps()
    end

    create unique_index(:agents, [:workspace_id, :slug])
  end
end
