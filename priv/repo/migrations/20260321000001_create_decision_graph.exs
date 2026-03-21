defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateDecisionGraph do
  use Ecto.Migration

  def change do
    create table(:decision_nodes, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :type, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :confidence, :float, null: false, default: 1.0
      add :agent_name, :string
      add :team_id, :string, null: false
      add :session_id, :string
      add :metadata, :map, default: %{}

      timestamps(type: :naive_datetime_usec)
    end

    create index(:decision_nodes, [:team_id])
    create index(:decision_nodes, [:session_id])
    create index(:decision_nodes, [:type])
    create index(:decision_nodes, [:status])
    create index(:decision_nodes, [:team_id, :type])
    create index(:decision_nodes, [:team_id, :status])
    create index(:decision_nodes, [:confidence])

    create table(:decision_edges, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :source_id, :string, null: false, references(:decision_nodes, type: :string, on_delete: :delete_all)
      add :target_id, :string, null: false, references(:decision_nodes, type: :string, on_delete: :delete_all)
      add :type, :string, null: false
      add :rationale, :text
      add :weight, :float, null: false, default: 1.0

      timestamps(updated_at: false, type: :naive_datetime_usec)
    end

    create index(:decision_edges, [:source_id])
    create index(:decision_edges, [:target_id])
    create index(:decision_edges, [:type])
    create index(:decision_edges, [:source_id, :type])
    create index(:decision_edges, [:target_id, :type])
  end
end
