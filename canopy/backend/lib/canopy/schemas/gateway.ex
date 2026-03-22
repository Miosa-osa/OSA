defmodule Canopy.Schemas.Gateway do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gateways" do
    field :url, :string
    field :token, :string
    field :status, :string, default: "disconnected"
    field :latency_ms, :integer
    field :is_primary, :boolean, default: false
    field :last_probe_at, :utc_datetime

    timestamps()
  end

  def changeset(gateway, attrs) do
    gateway
    |> cast(attrs, [:url, :token, :status, :latency_ms, :is_primary])
    |> validate_required([:url])
    |> validate_inclusion(:status, ~w(connected disconnected error))
  end
end
