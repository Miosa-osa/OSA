defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks.Handler do
  @moduledoc """
  Validation and execution logic for `team_tasks`.

  Stages:
    * `validate/2`           — confirm action is present and a known value
    * `check_permissions/2`  — always allow (team state is agent-owned ETS)
    * `execute/2`             — dispatch to `OptimalSystemAgent.Team` callbacks
  """

  alias OptimalSystemAgent.Team
  alias OptimalSystemAgent.Tools.Builtins.TeamTasks.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    if action in Constants.valid_actions() do
      {:ok, input}
    else
      valid = Enum.join(Constants.valid_actions(), ", ")
      {:error, "Unknown action '#{action}'. Valid actions: #{valid}", -32_602}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "list"} = args, ctx) do
    team_id = team_id(args, ctx)
    tasks = Team.list_tasks(team_id)

    if tasks == [] do
      {:ok, "No tasks in team #{team_id}."}
    else
      lines =
        Enum.map_join(tasks, "\n", fn t ->
          dep_str =
            if t.dependencies != [],
              do: " [depends: #{Enum.join(t.dependencies, ", ")}]",
              else: ""

          assignee_str = if t.assignee, do: " → #{t.assignee}", else: ""
          "- [#{t.status}] #{t.id}: #{t.description}#{assignee_str}#{dep_str} (wave #{t.wave})"
        end)

      {:ok, "## Team Tasks (#{length(tasks)})\n\n#{lines}"}
    end
  end

  def execute(%{"action" => "claim", "task_id" => task_id} = args, ctx) do
    team_id = team_id(args, ctx)
    agent_id = agent_id(args, ctx)

    case Team.claim_task(team_id, task_id, agent_id) do
      {:ok, task} ->
        {:ok, "Claimed task #{task_id}: #{task.description}"}

      {:error, :not_found} ->
        {:ok, "Task #{task_id} not found."}

      {:error, :dependencies_not_met} ->
        {:ok, "Cannot claim #{task_id} — dependencies not yet completed."}

      {:error, {:wrong_status, status}} ->
        {:ok, "Cannot claim #{task_id} — status is #{status}."}
    end
  end

  def execute(%{"action" => "complete", "task_id" => task_id} = args, ctx) do
    team_id = team_id(args, ctx)
    result = Map.get(args, "result", "completed")

    case Team.complete_task(team_id, task_id, result) do
      {:ok, _task} -> {:ok, "Task #{task_id} marked complete."}
      {:error, :not_found} -> {:ok, "Task #{task_id} not found."}
    end
  end

  def execute(%{"action" => "scratchpad_write", "content" => content} = args, ctx) do
    team_id = team_id(args, ctx)
    agent_id = agent_id(args, ctx)
    Team.write_scratchpad(team_id, agent_id, content)
    {:ok, "Scratchpad updated."}
  end

  def execute(%{"action" => "scratchpad_read"} = args, ctx) do
    team_id = team_id(args, ctx)
    pads = Team.all_scratchpads(team_id)

    if pads == [] do
      {:ok, "No scratchpad entries for team #{team_id}."}
    else
      lines =
        Enum.map_join(pads, "\n\n", fn {agent, content} ->
          "### #{agent}\n#{content}"
        end)

      {:ok, lines}
    end
  end

  def execute(%{"action" => action}, _ctx) do
    {:ok,
     "Action '#{action}' requires additional parameters. " <>
       "Valid actions: #{Enum.join(Constants.valid_actions(), ", ")}"}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp team_id(args, _ctx), do: Map.get(args, "team_id", "default")

  defp agent_id(args, ctx) do
    Map.get(args, "__session_id__") ||
      (ctx && Map.get(ctx, :session_id)) ||
      "unknown"
  end
end
