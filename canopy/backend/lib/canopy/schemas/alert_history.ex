defmodule Canopy.Schemas.AlertHistory do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "alert_history" do
    field :entity_value, :string
    field :resolved, :boolean, default: false
    field :inserted_at, :utc_datetime

    belongs_to :rule, Canopy.Schemas.AlertRule
  end

  def changeset(history, attrs) do
    history
    |> cast(attrs, [:entity_value, :resolved, :rule_id])
    |> validate_required([:rule_id])
  end
end
