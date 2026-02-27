defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateTaskQueue do
  use Ecto.Migration

  def change do
    create table(:task_queue) do
      add :task_id, :string, null: false
      add :agent_id, :string, null: false
      add :payload, :map, default: %{}
      add :status, :string, null: false, default: "pending"
      add :leased_until, :utc_datetime_usec
      add :leased_by, :string
      add :result, :map
      add :error, :text
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :completed_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:task_queue, [:task_id])
    create index(:task_queue, [:agent_id, :status])
    create index(:task_queue, [:status, :leased_until])
  end
end
