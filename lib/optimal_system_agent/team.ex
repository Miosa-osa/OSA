defmodule OptimalSystemAgent.Team do
  @moduledoc """
  Team coordination — shared task list, inter-agent messaging, and scratchpad.

  Provides the coordination layer for agent teams. All state is stored in ETS
  for lock-free concurrent access from multiple subagent processes.

  ## Components

  - **Task List**: shared work items with states (pending → in_progress → completed)
    and dependency tracking. Agents claim tasks, mark completion, and blocked
    tasks auto-unblock when dependencies resolve.

  - **Mailbox**: PubSub-based messaging between agents. Any agent can message
    any other agent in the same team.

  - **Scratchpad**: per-agent working memory stored in ETS. Agents write findings,
    intermediate results, and notes that other agents can read.

  ## ETS Tables

  - `:osa_team_tasks` — {team_id, task_id} → task map
  - `:osa_team_messages` — {team_id, recipient} → [message]
  - `:osa_team_scratchpad` — {team_id, agent_id} → content string
  """
  require Logger

  @tasks_table :osa_team_tasks
  @messages_table :osa_team_messages
  @scratchpad_table :osa_team_scratchpad
  @budget_table :osa_team_budgets

  # ---------------------------------------------------------------------------
  # Boot — create ETS tables
  # ---------------------------------------------------------------------------

  @doc "Create ETS tables for team coordination. Called from application.ex."
  def init_tables do
    :ets.new(@tasks_table, [:named_table, :public, :set])
    :ets.new(@messages_table, [:named_table, :public, :bag])
    :ets.new(@scratchpad_table, [:named_table, :public, :set])
    :ets.new(@budget_table, [:named_table, :public, :set])
    :ok
  rescue
    # Already exists
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Iteration Budget (shared counter across parent + children)
  # ---------------------------------------------------------------------------

  @doc "Initialize an iteration budget for a team. Default: 100 iterations."
  def init_budget(team_id, max_iterations \\ 100) do
    :ets.insert(@budget_table, {team_id, max_iterations, 0})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Consume one iteration from the budget. Returns {:ok, remaining} or {:exhausted, 0}."
  def consume_iteration(team_id) do
    try do
      used = :ets.update_counter(@budget_table, team_id, {3, 1}, {team_id, 100, 0})
      [{_, max, _}] = :ets.lookup(@budget_table, team_id)
      remaining = max - used
      if remaining > 0, do: {:ok, remaining}, else: {:exhausted, 0}
    rescue
      # No budget set — unlimited
      _ -> {:ok, 100}
    end
  end

  @doc "Get current budget status."
  def budget_status(team_id) do
    case :ets.lookup(@budget_table, team_id) do
      [{_, max, used}] -> %{max: max, used: used, remaining: max - used}
      [] -> %{max: :unlimited, used: 0, remaining: :unlimited}
    end
  rescue
    _ -> %{max: :unlimited, used: 0, remaining: :unlimited}
  end

  # ---------------------------------------------------------------------------
  # Task List
  # ---------------------------------------------------------------------------

  @doc """
  Create a task in the shared task list.

  Returns the task map with generated ID.
  """
  def create_task(team_id, attrs) do
    task_id = "task_#{System.unique_integer([:positive])}"

    task = %{
      id: task_id,
      team_id: team_id,
      description: Map.get(attrs, :description, ""),
      status: :pending,
      assignee: nil,
      role: Map.get(attrs, :role),
      tier: Map.get(attrs, :tier, :specialist),
      dependencies: Map.get(attrs, :dependencies, []),
      result: nil,
      wave: Map.get(attrs, :wave, 1),
      created_at: DateTime.utc_now()
    }

    :ets.insert(@tasks_table, {{team_id, task_id}, task})
    task
  end

  @doc "Get a task by ID."
  def get_task(team_id, task_id) do
    case :ets.lookup(@tasks_table, {team_id, task_id}) do
      [{_, task}] -> task
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "List all tasks for a team."
  def list_tasks(team_id) do
    :ets.match_object(@tasks_table, {{team_id, :_}, :_})
    |> Enum.map(fn {_, task} -> task end)
    |> Enum.sort_by(& &1.wave)
  rescue
    _ -> []
  end

  @doc "Claim a task — set status to :in_progress and assign to agent."
  def claim_task(team_id, task_id, agent_id) do
    case get_task(team_id, task_id) do
      nil ->
        {:error, :not_found}

      %{status: :pending} = task ->
        if dependencies_met?(team_id, task) do
          updated = %{task | status: :in_progress, assignee: agent_id}
          :ets.insert(@tasks_table, {{team_id, task_id}, updated})
          {:ok, updated}
        else
          {:error, :dependencies_not_met}
        end

      %{status: status} ->
        {:error, {:wrong_status, status}}
    end
  end

  @doc "Complete a task — set status to :completed with result."
  def complete_task(team_id, task_id, result) do
    case get_task(team_id, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        updated = %{task | status: :completed, result: result}
        :ets.insert(@tasks_table, {{team_id, task_id}, updated})

        # Check if any blocked tasks are now unblocked
        unblocked = check_unblocked(team_id, task_id)

        if unblocked != [] do
          Logger.info(
            "[Team] Tasks unblocked by #{task_id}: #{inspect(Enum.map(unblocked, & &1.id))}"
          )
        end

        {:ok, updated}
    end
  end

  @doc "Fail a task."
  def fail_task(team_id, task_id, error) do
    case get_task(team_id, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        updated = %{task | status: :failed, result: "FAILED: #{error}"}
        :ets.insert(@tasks_table, {{team_id, task_id}, updated})
        {:ok, updated}
    end
  end

  @doc "Get the next claimable task (pending + dependencies met)."
  def next_available_task(team_id) do
    list_tasks(team_id)
    |> Enum.find(fn task ->
      task.status == :pending and dependencies_met?(team_id, task)
    end)
  end

  @doc "Check if all dependencies for a task are completed."
  def dependencies_met?(team_id, task) do
    Enum.all?(task.dependencies, fn dep_id ->
      case get_task(team_id, dep_id) do
        %{status: :completed} -> true
        _ -> false
      end
    end)
  end

  @doc "Get tasks grouped by wave."
  def tasks_by_wave(team_id) do
    list_tasks(team_id)
    |> Enum.group_by(& &1.wave)
    |> Enum.sort_by(fn {wave, _} -> wave end)
  end

  @doc "Clean up all team state."
  def cleanup(team_id) do
    # Delete all tasks
    :ets.match_delete(@tasks_table, {{team_id, :_}, :_})
    # Delete all messages
    :ets.match_delete(@messages_table, {{team_id, :_}, :_})
    # Delete all scratchpads
    :ets.match_delete(@scratchpad_table, {{team_id, :_}, :_})
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Messaging
  # ---------------------------------------------------------------------------

  @doc "Send a message from one agent to another."
  def send_message(team_id, from, to, content) do
    msg = %{
      from: from,
      to: to,
      content: content,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(@messages_table, {{team_id, to}, msg})

    # Also broadcast via PubSub for real-time delivery
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:team:#{team_id}:#{to}",
      {:team_message, msg}
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc "Read all messages for an agent."
  def read_messages(team_id, agent_id) do
    :ets.lookup(@messages_table, {team_id, agent_id})
    |> Enum.map(fn {_, msg} -> msg end)
    |> Enum.sort_by(& &1.timestamp)
  rescue
    _ -> []
  end

  @doc "Broadcast a message to all agents in a team."
  def broadcast_message(team_id, from, content) do
    # Get all unique assignees
    agents =
      list_tasks(team_id)
      |> Enum.map(& &1.assignee)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(agents, fn agent_id ->
      if agent_id != from do
        send_message(team_id, from, agent_id, content)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Scratchpad
  # ---------------------------------------------------------------------------

  @doc """
  Write to an agent's scratchpad.

  The ETS write is the fast, ephemeral coordination path (unchanged). Passing
  `mirror: true` ALSO mirrors the content to the durable, inspectable file
  scratchpad (`OptimalSystemAgent.Scratchpad`) under the team's shared
  directory as `<agent_id>.md`, complementing (not replacing) the ETS surface.
  Mirroring is best-effort and never fails the ETS write.
  """
  def write_scratchpad(team_id, agent_id, content, opts \\ []) do
    :ets.insert(@scratchpad_table, {{team_id, agent_id}, content})

    if Keyword.get(opts, :mirror, false) do
      mirror_to_file_scratchpad(team_id, agent_id, content)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp mirror_to_file_scratchpad(team_id, agent_id, content) do
    safe_name = Regex.replace(~r/[^A-Za-z0-9_\-]/, to_string(agent_id), "_") <> ".md"
    OptimalSystemAgent.Scratchpad.write(team_id, safe_name, content)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Read an agent's scratchpad."
  def read_scratchpad(team_id, agent_id) do
    case :ets.lookup(@scratchpad_table, {team_id, agent_id}) do
      [{_, content}] -> content
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Read all scratchpads for a team."
  def all_scratchpads(team_id) do
    :ets.match_object(@scratchpad_table, {{team_id, :_}, :_})
    |> Enum.map(fn {{_, agent_id}, content} -> {agent_id, content} end)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_unblocked(team_id, completed_task_id) do
    list_tasks(team_id)
    |> Enum.filter(fn task ->
      task.status == :pending and
        completed_task_id in task.dependencies and
        dependencies_met?(team_id, task)
    end)
  end
end
