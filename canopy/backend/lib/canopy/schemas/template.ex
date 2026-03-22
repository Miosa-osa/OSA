defmodule Canopy.Schemas.Template do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "templates" do
    field :name, :string
    field :description, :string
    field :category, :string, default: "custom"
    field :agents, :map, default: %{}
    field :skills, :map, default: %{}
    field :schedules, :map, default: %{}
    field :is_builtin, :boolean, default: false

    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :description, :category, :agents, :skills, :schedules, :is_builtin])
    |> validate_required([:name])
  end
end
