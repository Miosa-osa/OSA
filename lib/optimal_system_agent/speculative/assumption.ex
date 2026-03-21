defmodule OptimalSystemAgent.Speculative.Assumption do
  @moduledoc """
  Assumption tracking for speculative execution.

  An assumption is a belief about the world that must hold for speculative work
  to be promotable. Assumptions are checked before promotion: if any are
  invalidated the speculative work is discarded.

  ## Status lifecycle

      :pending → :confirmed   (check_assumptions/1 found it still true)
      :pending → :invalidated (check_assumptions/1 found it false, or explicit invalidate/2)

  ## Example

      assumption = Assumption.new("user_intent_unchanged", "User is still working on auth feature")

      # Later, when validating:
      case Assumption.check(assumption, current_context) do
        {:ok, confirmed} -> ...
        {:invalidated, reason} -> ...
      end
  """

  @enforce_keys [:id, :description]
  defstruct id: nil,
            description: "",
            status: :pending,
            checked_at: nil,
            invalidation_reason: nil

  @type status :: :pending | :confirmed | :invalidated

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          status: status(),
          checked_at: DateTime.t() | nil,
          invalidation_reason: String.t() | nil
        }

  # ── Construction ──────────────────────────────────────────────────────────

  @doc "Create a new assumption in :pending state."
  @spec new(String.t(), String.t()) :: t()
  def new(id, description) when is_binary(id) and is_binary(description) do
    %__MODULE__{id: id, description: description, status: :pending}
  end

  @doc "Build assumptions from a list of description strings (auto-generates ids)."
  @spec from_descriptions([String.t()]) :: [t()]
  def from_descriptions(descriptions) when is_list(descriptions) do
    descriptions
    |> Enum.with_index(1)
    |> Enum.map(fn {desc, idx} ->
      new("assumption_#{idx}", desc)
    end)
  end

  # ── State Transitions ──────────────────────────────────────────────────────

  @doc "Mark an assumption as confirmed."
  @spec confirm(t()) :: t()
  def confirm(%__MODULE__{} = assumption) do
    %{assumption | status: :confirmed, checked_at: DateTime.utc_now()}
  end

  @doc """
  Mark an assumption as invalidated.

  `reason` should describe what changed that broke the assumption.
  """
  @spec invalidate(t(), String.t()) :: t()
  def invalidate(%__MODULE__{} = assumption, reason \\ "invalidated") do
    %{assumption | status: :invalidated, checked_at: DateTime.utc_now(), invalidation_reason: reason}
  end

  # ── Bulk Operations ────────────────────────────────────────────────────────

  @doc """
  Check a list of assumptions against `current_context`.

  The `check_fn` is a user-supplied function `(assumption, context) -> :ok | {:invalid, reason}`.
  Returns `{:ok, confirmed_list}` if all assumptions hold, or
  `{:invalidated, failed_list}` if any fail.

  ## Example check_fn

      fn assumption, ctx ->
        case assumption.id do
          "task_still_pending" ->
            if ctx.task.status == :pending, do: :ok, else: {:invalid, "task already started"}
          _ ->
            :ok
        end
      end
  """
  @spec check_assumptions([t()], map(), function()) :: {:ok, [t()]} | {:invalidated, [t()]}
  def check_assumptions(assumptions, current_context, check_fn)
      when is_list(assumptions) and is_function(check_fn, 2) do
    results =
      Enum.map(assumptions, fn assumption ->
        case check_fn.(assumption, current_context) do
          :ok -> confirm(assumption)
          {:invalid, reason} -> invalidate(assumption, reason)
        end
      end)

    failed = Enum.filter(results, &(&1.status == :invalidated))

    if failed == [] do
      {:ok, results}
    else
      {:invalidated, failed}
    end
  end

  @doc """
  Bulk-invalidate a list of assumptions with a single reason.
  Used when aborting speculative execution wholesale.
  """
  @spec invalidate_all([t()], String.t()) :: [t()]
  def invalidate_all(assumptions, reason \\ "speculative work discarded") do
    Enum.map(assumptions, &invalidate(&1, reason))
  end

  # ── Queries ────────────────────────────────────────────────────────────────

  @doc "True if all assumptions in the list are :confirmed."
  @spec all_confirmed?([t()]) :: boolean()
  def all_confirmed?(assumptions), do: Enum.all?(assumptions, &(&1.status == :confirmed))

  @doc "True if any assumption in the list is :invalidated."
  @spec any_invalidated?([t()]) :: boolean()
  def any_invalidated?(assumptions), do: Enum.any?(assumptions, &(&1.status == :invalidated))

  @doc "Filter to only invalidated assumptions."
  @spec invalidated([t()]) :: [t()]
  def invalidated(assumptions), do: Enum.filter(assumptions, &(&1.status == :invalidated))

  @doc "Serialize to a plain map (for storage / event payloads)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = a) do
    %{
      id: a.id,
      description: a.description,
      status: a.status,
      checked_at: a.checked_at && DateTime.to_iso8601(a.checked_at),
      invalidation_reason: a.invalidation_reason
    }
  end
end
