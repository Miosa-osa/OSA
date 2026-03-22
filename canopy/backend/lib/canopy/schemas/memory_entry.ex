defmodule Canopy.Schemas.MemoryEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "memory_entries" do
    field :key, :string
    field :content, :string
    field :category, :string
    field :tags, {:array, :string}

    belongs_to :workspace, Canopy.Schemas.Workspace
    belongs_to :agent, Canopy.Schemas.Agent

    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :content, :category, :tags, :workspace_id, :agent_id])
    |> validate_required([:key, :content, :workspace_id])
  end
end
