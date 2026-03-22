defmodule Canopy.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  def change do
    create table(:gateways, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :string, null: false
      add :token, :string
      add :status, :string, null: false, default: "disconnected"
      add :latency_ms, :integer
      add :is_primary, :boolean, null: false, default: false
      add :last_probe_at, :utc_datetime
      timestamps()
    end
  end
end
