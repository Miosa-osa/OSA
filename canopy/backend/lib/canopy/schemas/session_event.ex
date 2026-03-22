defmodule Canopy.Schemas.SessionEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "session_events" do
    field :event_type, :string
    field :data, :map
    field :tokens, :integer, default: 0
    field :inserted_at, :utc_datetime

    belongs_to :session, Canopy.Schemas.Session
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :data, :tokens, :session_id, :inserted_at])
    |> validate_required([:event_type, :data, :session_id])
  end
end
