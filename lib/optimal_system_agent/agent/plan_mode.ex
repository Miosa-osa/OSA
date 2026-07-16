defmodule OptimalSystemAgent.Agent.PlanMode do
  @moduledoc """
  Plan → approve → execute round-trip for the HTTP / TUI channel.

  The TUI's `plan_review` dialog POSTs `plan_approve` / `plan_reject` /
  `plan_edit` to `/commands/execute`. Those map here. The pending plan and the
  original user input were stashed in `PlanStore` when the plan was produced,
  so the client never has to echo the plan text back.

  Execution is dispatched asynchronously via `SessionManager` — the HTTP
  request returns immediately and results stream back over the session's SSE
  channel, exactly like a normal `/input` turn.
  """
  require Logger

  alias OptimalSystemAgent.Agent.PlanStore
  alias OptimalSystemAgent.Runtime.SessionManager

  @doc """
  Approve the pending plan and resume execution with `skip_plan: true` so the
  loop runs it directly instead of re-planning.
  """
  @spec approve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def approve(session_id) when is_binary(session_id) do
    case PlanStore.take(session_id) do
      %{plan: plan, input: input} ->
        execute_msg =
          "Execute the following approved plan. Do not re-plan — proceed directly " <>
            "with implementation.\n\n#{plan}\n\nOriginal request: #{input}"

        SessionManager.process_message_async(session_id, execute_msg, skip_plan: true)
        Logger.info("[PlanMode] Plan approved — resuming execution for #{session_id}")
        {:ok, "Plan approved — executing."}

      nil ->
        {:error, "No plan awaiting approval for this session."}
    end
  end

  def approve(_), do: {:error, "Invalid session."}

  @doc "Reject and discard the pending plan."
  @spec reject(String.t()) :: {:ok, String.t()}
  def reject(session_id) when is_binary(session_id) do
    PlanStore.clear(session_id)
    {:ok, "Plan rejected."}
  end

  def reject(_), do: {:ok, "Plan rejected."}

  @doc """
  Edit the pending plan.

  With `feedback` text, re-plan (no `skip_plan`) so a fresh plan is produced
  and a new `plan_proposed` event round-trips back to the client. With empty
  feedback (the TUI's default — it drops back to Idle for the user to type),
  the pending plan is kept and plan mode stays enabled, so the user's next
  message re-plans naturally.
  """
  @spec edit(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def edit(session_id, feedback) when is_binary(session_id) do
    case PlanStore.get(session_id) do
      %{plan: plan, input: input} ->
        case String.trim(feedback || "") do
          "" ->
            {:ok, "Plan editing — send your revised instructions."}

          trimmed ->
            revise_msg =
              "Revise your plan based on this feedback:\n\n#{trimmed}\n\n" <>
                "Original plan:\n#{plan}\n\nOriginal request: #{input}"

            SessionManager.process_message_async(session_id, revise_msg)
            Logger.info("[PlanMode] Plan edit — revising for #{session_id}")
            {:ok, "Revising plan…"}
        end

      nil ->
        {:error, "No plan awaiting revision for this session."}
    end
  end

  def edit(_, _), do: {:error, "Invalid session."}
end
