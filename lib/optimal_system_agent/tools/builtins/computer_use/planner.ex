defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Planner do
  @moduledoc """
  PPEV Planner — Perceive → Plan → Execute → Verify loop.

  Inspired by MIT VLMFP (2026): structured loop instead of blind
  action-by-action guessing. Each action is verified before proceeding,
  and the plan adapts when reality diverges from expectations.

  Also incorporates ICRL curriculum: planner accepts optional worked
  examples that are gradually replaced by learned skills.
  """

  @max_replans 3

  defstruct [
    :goal,
    phase: :perceive,
    current_tree: nil,
    actions: [],
    history: [],
    replan_count: 0,
    examples: []
  ]

  # ── Public API ──────────────────────────────────────────────────────

  @doc "Create a new planner for a goal."
  def new(goal, examples \\ []) do
    %__MODULE__{goal: goal, examples: examples}
  end

  @doc "Set perception result and advance to :plan phase."
  def set_perception(planner, tree_text) do
    %{planner | current_tree: tree_text, phase: :plan}
  end

  @doc "Set the action plan and advance to :execute phase."
  def set_plan(planner, actions) when is_list(actions) do
    %{planner | actions: actions, phase: :execute}
  end

  @doc "Get the next action to execute. Returns {action, updated_planner} or {nil, planner}."
  def next_action(%{actions: []} = planner), do: {nil, planner}

  def next_action(%{actions: [action | rest]} = planner) do
    {action, %{planner | actions: rest}}
  end

  @doc "Mark an action as executed and advance to :verify phase."
  def mark_executed(planner, action, result) do
    entry = %{action: action, result: result, timestamp: System.system_time(:millisecond)}

    %{planner | history: planner.history ++ [entry], phase: :verify}
  end

  @doc "Verification succeeded. If more actions remain, continue executing. Otherwise done."
  def verify_success(%{actions: []} = planner) do
    %{planner | phase: :done}
  end

  def verify_success(planner) do
    %{planner | phase: :execute}
  end

  @doc "Verification failed. Re-enter perceive for replan."
  def verify_failure(planner, _reason) do
    %{planner | phase: :perceive, replan_count: planner.replan_count + 1, actions: []}
  end

  @doc "Is the planner stuck? True after #{@max_replans} consecutive replans."
  def stuck?(%{replan_count: n}), do: n >= @max_replans

  @doc "Human-readable summary of the planner state."
  def summary(planner) do
    steps = length(planner.history)
    status = to_string(planner.phase)

    """
    Goal: #{planner.goal}
    Status: #{status}
    Steps completed: #{steps}
    Replans: #{planner.replan_count}/#{@max_replans}
    """
    |> String.trim()
  end
end
