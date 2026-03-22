defmodule Canopy.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :string, null: false
      add :password_hash, :string
      add :role, :string, null: false, default: "member"
      add :provider, :string, null: false, default: "local"
      add :last_login, :utc_datetime
      timestamps()
    end

    create unique_index(:users, [:email])
  end
end
