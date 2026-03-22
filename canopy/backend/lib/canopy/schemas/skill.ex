defmodule Canopy.Schemas.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "skills" do
    field :name, :string
    field :description, :string
    field :category, :string
    field :trigger_rules, :map, default: %{}
    field :enabled, :boolean, default: true

    belongs_to :workspace, Canopy.Schemas.Workspace
    many_to_many :agents, Canopy.Schemas.Agent, join_through: "agent_skills"

    timestamps()
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :description, :category, :trigger_rules, :enabled, :workspace_id])
    |> validate_required([:name, :category, :workspace_id])
    |> validate_inclusion(:category, ~w(Development Research Communication Analysis Operations Custom))
  end
end
