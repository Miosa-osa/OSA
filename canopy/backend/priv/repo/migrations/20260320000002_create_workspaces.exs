defmodule Canopy.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :path, :string, null: false
      add :status, :string, null: false, default: "active"
      add :owner_id, references(:users, type: :binary_id)
      timestamps()
    end
  end
end
