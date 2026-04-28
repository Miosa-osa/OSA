defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks do
  @moduledoc """
  View and manage the shared team task list.

  Agents use this to see what tasks exist, check status, claim work,
  and mark tasks complete. The task list is shared across all agents
  in a team via ETS.
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Team

  @impl true
  def name, do: "team_tasks"

  @impl true
  def description do
    "View and manage the shared team task list. " <>
      "See all tasks, their status, dependencies, and assignees. " <>
      "Claim pending tasks or mark your tasks complete."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "claim", "complete", "scratchpad_write", "scratchpad_read"],
          "description" =>
            "Action: list (view all tasks), claim (take a pending task), complete (mark done), scratchpad_write (save notes), scratchpad_read (read team notes)"
        },
        "team_id" => %{
          "type" => "string",
          "description" => "Team identifier. Required for all actions."
        },
        "task_id" => %{
          "type" => "string",
          "description" => "Task ID for claim/complete actions."
        },
        "result" => %{
          "type" => "string",
          "description" => "Result text when completing a task."
        },
        "content" => %{
          "type" => "string",
          "description" => "Content for scratchpad_write."
        }
      }
    }
  end

  @impl true
  def execute(%{"action" => "list"} = args) do
    team_id = Map.get(args, "team_id", "default")
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

  def execute(%{"action" => "claim", "task_id" => task_id} = args) do
    team_id = Map.get(args, "team_id", "default")
    agent_id = Map.get(args, "__session_id__", "unknown")

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

  def execute(%{"action" => "complete", "task_id" => task_id} = args) do
    team_id = Map.get(args, "team_id", "default")
    result = Map.get(args, "result", "completed")

    case Team.complete_task(team_id, task_id, result) do
      {:ok, _task} -> {:ok, "Task #{task_id} marked complete."}
      {:error, :not_found} -> {:ok, "Task #{task_id} not found."}
    end
  end

  def execute(%{"action" => "scratchpad_write", "content" => content} = args) do
    team_id = Map.get(args, "team_id", "default")
    agent_id = Map.get(args, "__session_id__", "unknown")
    Team.write_scratchpad(team_id, agent_id, content)
    {:ok, "Scratchpad updated."}
  end

  def execute(%{"action" => "scratchpad_read"} = args) do
    team_id = Map.get(args, "team_id", "default")
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

  def execute(_),
    do: {:ok, "Invalid action. Use: list, claim, complete, scratchpad_write, scratchpad_read"}
end
