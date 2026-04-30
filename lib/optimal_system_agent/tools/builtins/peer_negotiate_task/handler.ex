defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `peer_negotiate_task`.

  Split mirrors the structured-layout pattern:
    * `validate/2`          — type-check input shape
    * `check_permissions/2` — deny read-only contexts
    * `execute/2`           — dispatch to `OptimalSystemAgent.Peer.Negotiation`
  """

  alias OptimalSystemAgent.Peer.Negotiation
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Validate ─────────────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action, "negotiation_id" => _} = input, _ctx)
      when action in ["counter", "accept", "reject", "status"] do
    {:ok, input}
  end

  def validate(%{"action" => action}, _ctx)
      when action in ["counter", "accept", "reject", "status"] do
    {:error, "Missing required parameter: negotiation_id", -32_602}
  end

  def validate(%{"action" => other}, _ctx) do
    {:error, "Invalid action '#{other}'. Use: counter, accept, reject, status", -32_602}
  end

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: action, negotiation_id", -32_602}

  # ── Stage 2: Permissions ──────────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(_input, %UseContext{read_only_request?: true}) do
    {:deny, "Access denied: peer_negotiate_task is not available in read-only mode"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(
        %{
          "action" => "counter",
          "negotiation_id" => neg_id,
          "counter_agent" => counter_agent
        } = args,
        _ctx
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

  def execute(%{"action" => "counter"}, _ctx) do
    {:error, "Missing required parameter: counter_agent is required for 'counter' action."}
  end

  def execute(%{"action" => "accept", "negotiation_id" => neg_id} = args, ctx) do
    agent_id = ctx.session_id || Map.get(args, "__session_id__", "unknown")

    case Negotiation.accept_assignment(neg_id, by: agent_id) do
      {:ok, negotiation} ->
        {:ok, "Assignment accepted for task #{negotiation.task_id}. You are now assigned."}

      {:error, reason} ->
        {:error, "Failed to accept: #{reason}"}
    end
  end

  def execute(%{"action" => "reject", "negotiation_id" => neg_id} = args, _ctx) do
    reason = Map.get(args, "reason", "Cannot complete this task.")

    case Negotiation.reject_assignment(neg_id, reason) do
      {:ok, negotiation} ->
        {:ok, "Assignment rejected for task #{negotiation.task_id}. Reason: #{reason}"}

      {:error, reason_msg} ->
        {:error, "Failed to reject: #{reason_msg}"}
    end
  end

  def execute(%{"action" => "status", "negotiation_id" => neg_id}, _ctx) do
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
end
