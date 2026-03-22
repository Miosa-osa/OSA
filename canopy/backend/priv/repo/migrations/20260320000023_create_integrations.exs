defmodule Canopy.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  def change do
    create table(:integrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :category, :string, null: false
      add :config, :map, default: %{}
      add :connected, :boolean, null: false, default: false
      add :last_synced_at, :utc_datetime
      timestamps()
    end

    create unique_index(:integrations, [:workspace_id, :slug])
  end
end
