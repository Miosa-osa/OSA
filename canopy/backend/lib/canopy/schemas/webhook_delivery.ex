defmodule Canopy.Schemas.WebhookDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "webhook_deliveries" do
    field :status_code, :integer
    field :payload, :map
    field :response, :string
    field :inserted_at, :utc_datetime

    belongs_to :webhook, Canopy.Schemas.Webhook
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:status_code, :payload, :response, :webhook_id])
    |> validate_required([:payload, :webhook_id])
  end
end
