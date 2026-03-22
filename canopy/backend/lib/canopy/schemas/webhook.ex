defmodule Canopy.Schemas.Webhook do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webhooks" do
    field :name, :string
    field :webhook_type, :string
    field :url, :string
    field :events, {:array, :string}
    field :secret, :string
    field :enabled, :boolean, default: true
    field :last_triggered_at, :utc_datetime

    belongs_to :workspace, Canopy.Schemas.Workspace
    has_many :deliveries, Canopy.Schemas.WebhookDelivery

    timestamps()
  end

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :webhook_type, :url, :events, :secret, :enabled, :workspace_id])
    |> validate_required([:name, :webhook_type, :url, :events, :workspace_id])
    |> validate_inclusion(:webhook_type, ~w(incoming outgoing))
  end
end
