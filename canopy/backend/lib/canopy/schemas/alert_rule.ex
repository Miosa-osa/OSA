defmodule Canopy.Schemas.AlertRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "alert_rules" do
    field :name, :string
    field :description, :string
    field :entity, :string
    field :field, :string
    field :operator, :string
    field :value, :string
    field :cooldown_minutes, :integer, default: 60
    field :notify_targets, :map, default: %{}
    field :enabled, :boolean, default: true
    field :trigger_count, :integer, default: 0
    field :last_triggered_at, :utc_datetime

    belongs_to :workspace, Canopy.Schemas.Workspace
    has_many :history, Canopy.Schemas.AlertHistory, foreign_key: :rule_id

    timestamps()
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:name, :description, :entity, :field, :operator, :value, :cooldown_minutes, :notify_targets, :enabled, :workspace_id])
    |> validate_required([:name, :entity, :field, :operator, :value, :workspace_id])
    |> validate_inclusion(:entity, ~w(Agent Session Budget System Gateway))
  end
end
