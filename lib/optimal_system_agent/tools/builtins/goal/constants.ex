defmodule OptimalSystemAgent.Tools.Builtins.Goal.Constants do
  @moduledoc """
  Exported constants for the `create_goal` / `update_goal` pair.
  """

  @create_tool_name "create_goal"
  def create_tool_name, do: @create_tool_name

  @update_tool_name "update_goal"
  def update_tool_name, do: @update_tool_name

  # Codex caps the objective at `MAX_THREAD_GOAL_OBJECTIVE_CHARS`
  # (`validate_thread_goal_objective/1`). Same idea: an objective is a contract
  # line, not a design document, and it is re-injected into context every single
  # turn for the life of the goal.
  @max_objective_chars 4_000
  def max_objective_chars, do: @max_objective_chars

  @max_criteria_chars 8_000
  def max_criteria_chars, do: @max_criteria_chars

  @max_result_size_chars 4_000
  def max_result_size_chars, do: @max_result_size_chars

  # The only statuses the MODEL may set. Codex rejects everything else with
  # "update_goal can only mark the existing goal complete or blocked; pause,
  # resume, budget-limited, and usage-limited status changes are controlled by
  # the user or system".
  #
  # `abandoned` is the one deliberate addition to Codex's pair. Codex's set left
  # an agent whose work legitimately changed direction with no reachable exit at
  # all — `complete` is a claim the panel adjudicates, `blocked` needs three
  # consecutive top-level turns, and pause/resume/clear are the user's. Under an
  # unattended `overdrive` run that is a deadlock. See `GoalTracker.abandon/1`
  # for what it costs, which is what keeps it from being the easy-goal loophole.
  @model_statuses ~w(complete blocked abandoned awaiting_user)
  def model_statuses, do: @model_statuses
end
