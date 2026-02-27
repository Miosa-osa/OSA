defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :session_id, :string, null: false
      add :role, :string, null: false
      add :content, :text
      add :tool_calls, :map
      add :tool_call_id, :string
      add :signal_mode, :string
      add :signal_weight, :float
      add :token_count, :integer
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:messages, [:session_id])
    create index(:messages, [:session_id, :inserted_at])
    create index(:messages, [:role])
  end
end
