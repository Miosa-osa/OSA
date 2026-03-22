defmodule Canopy.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :author_type, :string, null: false
      add :author_id, :binary_id, null: false
      add :body, :text, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:comments, [:issue_id])
  end
end
