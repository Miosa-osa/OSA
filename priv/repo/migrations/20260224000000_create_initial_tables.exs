defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateInitialTables do
  use Ecto.Migration

  def change do
    create table(:contacts) do
      add :name, :string, null: false
      add :aliases, {:array, :string}, default: []
      add :channel, :string
      add :profile, :map, default: %{}
      timestamps()
    end

    create table(:conversations) do
      add :session_id, :string, null: false
      add :contact_id, references(:contacts, on_delete: :nilify_all)
      add :channel, :string, null: false
      add :depth, :string, default: "casual"
      add :message_count, :integer, default: 0
      add :metadata, :map, default: %{}
      timestamps()
    end

    create unique_index(:conversations, [:session_id])
  end
end
