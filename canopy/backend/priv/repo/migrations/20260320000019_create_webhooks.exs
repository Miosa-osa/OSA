defmodule Canopy.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :webhook_type, :string, null: false
      add :url, :string, null: false
      add :events, {:array, :string}, null: false
      add :secret, :string
      add :enabled, :boolean, null: false, default: true
      add :last_triggered_at, :utc_datetime
      timestamps()
    end
  end
end
