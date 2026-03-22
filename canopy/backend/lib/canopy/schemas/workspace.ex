defmodule Canopy.Schemas.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspaces" do
    field :name, :string
    field :path, :string
    field :status, :string, default: "active"

    belongs_to :owner, Canopy.Schemas.User
    has_many :agents, Canopy.Schemas.Agent
    has_many :projects, Canopy.Schemas.Project
    has_many :issues, Canopy.Schemas.Issue
    has_many :skills, Canopy.Schemas.Skill

    timestamps()
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :path, :status, :owner_id])
    |> validate_required([:name, :path])
    |> validate_inclusion(:status, ~w(active archived))
  end
end
