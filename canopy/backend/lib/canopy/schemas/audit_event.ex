defmodule Canopy.Schemas.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "audit_events" do
    field :action, :string
    field :actor, :string
    field :actor_type, :string
    field :entity_type, :string
    field :entity_id, :binary_id
    field :details, :map, default: %{}
    field :inserted_at, :utc_datetime
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :actor, :actor_type, :entity_type, :entity_id, :details])
    |> validate_required([:action, :actor, :actor_type])
    |> validate_inclusion(:actor_type, ~w(user agent system))
  end
end
