defmodule Canopy.Schemas.BudgetPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "budget_policies" do
    field :scope_type, :string
    field :scope_id, :binary_id
    field :monthly_limit_cents, :integer
    field :warning_threshold_pct, :integer, default: 80
    field :hard_stop, :boolean, default: true

    timestamps()
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:scope_type, :scope_id, :monthly_limit_cents, :warning_threshold_pct, :hard_stop])
    |> validate_required([:scope_type, :scope_id, :monthly_limit_cents])
    |> validate_inclusion(:scope_type, ~w(agent project workspace))
    |> validate_number(:monthly_limit_cents, greater_than: 0)
    |> validate_number(:warning_threshold_pct, greater_than: 0, less_than_or_equal_to: 100)
    |> unique_constraint([:scope_type, :scope_id])
  end
end
