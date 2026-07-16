defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation do
  @moduledoc """
  Graded escalation — the shared "nudge before halt" mechanism.

  When any detector notices the agent *approaching* a hard threshold it asks
  this module to advance a per-session graded sequence
  (reflect -> try something different -> decompose) and inject the next
  directive into the message history.

  State ownership is explicit: the escalation step count and the per-tick guard
  live on the threaded `state` (`:graded_escalation_count` /
  `:escalated_this_tick`) rather than the process dictionary, so the sequence is
  visible and testable. `:graded_escalation_count` persists for the whole
  session; `:escalated_this_tick` is reset at the start of every
  `DoomLoop.check/3`.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus

  # Graded escalation: before any hard halt, the agent is nudged to CHANGE
  # APPROACH. Each distinct "approaching" signal advances one step in a shared
  # per-session sequence (reflect -> try something different -> decompose).
  # After the steps are exhausted, control falls through to the existing hard
  # halts (identical-call cap, repeated-failure recovery, or the stall halt).
  @max_graded_escalations 3

  @doc "Total number of graded steps before escalation is exhausted."
  def max_steps, do: @max_graded_escalations

  # --- Graded escalation ---
  #
  # For "approaching a threshold" callers: nudge the agent, but never halt here
  # (the existing hard halts remain the backstop). Always returns `{:ok, state}`.
  @doc """
  Nudge for callers that are *approaching* a threshold. Never halts; always
  returns `{:ok, state}`.
  """
  def graded(reason, context, state) do
    case escalate(reason, context, state) do
      {:escalated, state} -> {:ok, state}
      {:exhausted, state} -> {:ok, state}
    end
  end

  # Advances the shared per-session graded sequence and injects the next
  # directive into the message history. Returns `{:escalated, state}` while
  # steps remain, or `{:exhausted, state}` once all steps have been used.
  # At most one directive is injected per `check/3` invocation.
  @doc """
  Advance the shared per-session graded sequence and inject the next directive.

  Returns `{:escalated, state}` while steps remain, or `{:exhausted, state}`
  once all steps have been used. At most one directive is injected per
  `DoomLoop.check/3` invocation (guarded by `:escalated_this_tick`).
  """
  def escalate(reason, context, state) do
    count = Map.get(state, :graded_escalation_count, 0)

    cond do
      count >= @max_graded_escalations ->
        {:exhausted, state}

      Map.get(state, :escalated_this_tick, false) ->
        # A directive was already injected this tick; don't stack another.
        {:escalated, state}

      true ->
        step = count + 1

        state =
          state
          |> Map.put(:graded_escalation_count, step)
          |> Map.put(:escalated_this_tick, true)

        directive = %{
          role: "system",
          content:
            "[CHANGE APPROACH — graded nudge #{step}/#{@max_graded_escalations}] " <>
              context <> " " <> graded_step_instruction(step)
        }

        Logger.info(
          "[doom] Graded escalation #{step}/#{@max_graded_escalations} (#{reason}) — " <>
            "injecting directive (session: #{state.session_id})"
        )

        Bus.emit(:system_event, %{
          event: :doom_graded_escalation,
          session_id: state.session_id,
          step: step,
          max_steps: @max_graded_escalations,
          reason: reason
        })

        messages = Map.get(state, :messages, [])
        state = Map.put(state, :messages, messages ++ [directive])

        {:escalated, state}
    end
  end

  defp graded_step_instruction(1) do
    "REFLECT before acting: why isn't this working? State the assumption that " <>
      "might be wrong, then act on that insight — do not simply retry."
  end

  defp graded_step_instruction(2) do
    "Reflection wasn't enough. Use a DIFFERENT tool or a fundamentally " <>
      "different approach than the one you have been repeating."
  end

  defp graded_step_instruction(3) do
    "You are still stuck. DECOMPOSE the task into smaller, concrete sub-steps " <>
      "and tackle only the first one, using a different method than before."
  end

  defp graded_step_instruction(_), do: "Change your approach now."
end
