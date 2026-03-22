defmodule Canopy.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries) do
      add :webhook_id, references(:webhooks, type: :binary_id, on_delete: :delete_all), null: false
      add :status_code, :integer
      add :payload, :map, null: false
      add :response, :text
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:webhook_deliveries, [:webhook_id])
  end
end
