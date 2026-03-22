defmodule Canopy.Repo.Migrations.CreateCostEvents do
  use Ecto.Migration

  def change do
    create table(:cost_events) do
      add :agent_id, references(:agents, type: :binary_id), null: false
      add :session_id, references(:sessions, type: :binary_id)
      add :model, :string, null: false
      add :tokens_input, :integer, null: false, default: 0
      add :tokens_output, :integer, null: false, default: 0
      add :tokens_cache, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:cost_events, [:agent_id])
    create index(:cost_events, [:session_id])
  end
end
