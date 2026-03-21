defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask do
  @moduledoc """
  Task Negotiation Tool — contest or redirect a task assignment.

  When an agent is assigned a task it believes it is not best suited for, it
  can use this tool to counter-propose a more appropriate teammate. The tool
  also supports accepting or rejecting assignments explicitly, and querying the
  current negotiation state for a task.

  ## Actions

  - `counter`  — suggest a better-suited agent for a task you've been assigned.
  - `accept`   — explicitly accept the assignment (bypass the auto-accept timer).
  - `reject`   — reject the assignment outright with a reason.
  - `status`   — check the current state of a negotiation.
  """
  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Peer.Negotiation

  @impl true
  def name, do: "peer_negotiate_task"

  @impl true
  def description do
    "Contest, redirect, or accept a task assignment. " <>
      "Use 'counter' to suggest a better-suited teammate. " <>
      "Use 'accept' to confirm you'll take the task. " <>
      "Use 'reject' if the task cannot be done. " <>
      "Use 'status' to check where a negotiation stands."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action", "negotiation_id"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["counter", "accept", "reject", "status"],
          "description" =>
            "counter: propose alternate agent, accept: take the task, reject: decline, status: check state"
        },
        "negotiation_id" => %{
          "type" => "string",
          "description" => "Negotiation ID from the task assignment notification."
        },
        "counter_agent" => %{
          "type" => "string",
          "description" => "Agent ID of the suggested replacement (required for 'counter')."
        },
        "reason" => %{
          "type" => "string",
          "description" => "Justification for counter or rejection."
        }
      }
    }
  end

  @impl true
  def safety, do: :write_safe

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @impl true
  def execute(
        %{"action" => "counter", "negotiation_id" => neg_id, "counter_agent" => counter_agent} =
          args
      ) do
    reason = Map.get(args, "reason", "I am not the best fit for this task.")

    case Negotiation.counter_propose(neg_id, counter_agent, reason) do
      {:ok, negotiation} ->
        {:ok,
         "Counter-proposal submitted for negotiation #{neg_id}.\n" <>
           "Suggested agent: #{counter_agent}\n" <>
           "Reason: #{reason}\n" <>
           "Task: #{negotiation.task_id}"}

      {:error, reason_msg} ->
        {:error, "Failed to counter-propose: #{reason_msg}"}
    end
  end

  def execute(%{"action" => "counter"}) do
    {:error, "Missing required parameter: counter_agent is required for 'counter' action."}
  end

  def execute(%{"action" => "accept", "negotiation_id" => neg_id} = args) do
    agent_id = Map.get(args, "__session_id__", "unknown")

    case Negotiation.accept_assignment(neg_id, by: agent_id) do
      {:ok, negotiation} ->
        {:ok, "Assignment accepted for task #{negotiation.task_id}. You are now assigned."}

      {:error, reason} ->
        {:error, "Failed to accept: #{reason}"}
    end
  end

  def execute(%{"action" => "reject", "negotiation_id" => neg_id} = args) do
    reason = Map.get(args, "reason", "Cannot complete this task.")

    case Negotiation.reject_assignment(neg_id, reason) do
      {:ok, negotiation} ->
        {:ok, "Assignment rejected for task #{negotiation.task_id}. Reason: #{reason}"}

      {:error, reason_msg} ->
        {:error, "Failed to reject: #{reason_msg}"}
    end
  end

  def execute(%{"action" => "status", "negotiation_id" => neg_id}) do
    case Negotiation.get_negotiation(neg_id) do
      nil ->
        {:ok, "Negotiation #{neg_id} not found."}

      negotiation ->
        counter_info =
          if negotiation.counter_agent do
            "\nCounter-proposal: #{negotiation.counter_agent} (#{negotiation.counter_reason})"
          else
            ""
          end

        history_lines =
          negotiation.history
          |> Enum.map_join("\n", fn entry ->
            "  - #{entry.event}: #{Map.get(entry, :agent, "")} #{Map.get(entry, :reason, "")}"
          end)

        {:ok,
         "## Negotiation #{neg_id}\n\n" <>
           "Task: #{negotiation.task_id}\n" <>
           "Status: **#{negotiation.status}**\n" <>
           "Proposed agent: #{negotiation.proposed_agent}" <>
           counter_info <>
           "\n\n**History:**\n#{history_lines}"}
    end
  end

  def execute(_) do
    {:error,
     "Invalid parameters. Required: action (counter|accept|reject|status), negotiation_id."}
  end
end
