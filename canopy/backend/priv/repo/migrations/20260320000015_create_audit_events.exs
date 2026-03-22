defmodule Canopy.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :action, :string, null: false
      add :actor, :string, null: false
      add :actor_type, :string, null: false
      add :entity_type, :string
      add :entity_id, :binary_id
      add :details, :map, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:audit_events, [:action])
    create index(:audit_events, [:actor_type])
  end
end
