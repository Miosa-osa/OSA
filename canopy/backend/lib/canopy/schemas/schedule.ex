defmodule Canopy.Schemas.Schedule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "schedules" do
    field :name, :string
    field :cron_expression, :string
    field :context, :string
    field :enabled, :boolean, default: true
    field :timezone, :string, default: "UTC"
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime
    field :last_run_status, :string

    belongs_to :workspace, Canopy.Schemas.Workspace
    belongs_to :agent, Canopy.Schemas.Agent

    timestamps()
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :cron_expression, :context, :enabled, :timezone, :workspace_id, :agent_id])
    |> validate_required([:name, :cron_expression, :workspace_id, :agent_id])
  end
end
