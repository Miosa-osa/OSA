defmodule Canopy.Schemas.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :description, :string
    field :status, :string, default: "active"

    belongs_to :workspace, Canopy.Schemas.Workspace
    has_many :goals, Canopy.Schemas.Goal
    has_many :issues, Canopy.Schemas.Issue

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :description, :status, :workspace_id])
    |> validate_required([:name, :workspace_id])
    |> validate_inclusion(:status, ~w(active archived completed))
  end
end
