defmodule Canopy.Repo.Migrations.CreateMemoryEntries do
  use Ecto.Migration

  def change do
    create table(:memory_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id)
      add :key, :string, null: false
      add :content, :text, null: false
      add :category, :string
      add :tags, {:array, :string}
      timestamps()
    end
  end
end
