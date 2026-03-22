defmodule Canopy.Schemas.ActivityEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "activity_events" do
    field :event_type, :string
    field :message, :string
    field :metadata, :map, default: %{}
    field :level, :string, default: "info"
    field :inserted_at, :utc_datetime

    belongs_to :workspace, Canopy.Schemas.Workspace
    belongs_to :agent, Canopy.Schemas.Agent
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :message, :metadata, :level, :workspace_id, :agent_id])
    |> validate_required([:event_type, :message, :workspace_id])
    |> validate_inclusion(:level, ~w(debug info warn error))
  end
end
