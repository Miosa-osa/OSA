defmodule Canopy.Repo.Migrations.CreateSessionEvents do
  use Ecto.Migration

  def change do
    create table(:session_events) do
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :data, :map, null: false
      add :tokens, :integer, default: 0
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:session_events, [:session_id])
  end
end
