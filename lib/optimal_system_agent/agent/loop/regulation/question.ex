defmodule OptimalSystemAgent.Agent.Loop.Regulation.Question do
  @moduledoc """
  "Ask one good question" (item 14).

  When `Pain` scores the turn `:high` AND classifies the cause as ambiguity —
  repeated re-verification of the same fact, or tool results that keep
  contradicting what issuing them implied — continuing to check is not making
  progress; the fastest path forward is to ask the user. This module injects
  exactly ONE minimal, user-visible instruction telling the model to do that,
  rather than a wall of text explaining the pain score.

  At most one per turn: `state[:regulation_question_asked]` is the guard,
  reset in `TurnPipeline.reset_per_turn_fields/1`. A model that ignores the
  instruction and keeps verifying anyway will still be caught by
  `Pain`'s `:critical` pause — this is a steer, not a stop.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @doc """
  Inject the single "stop and ask" directive if one has not already been
  injected this turn. Idempotent — safe to call every iteration while pain
  stays `:high`.
  """
  @spec maybe_inject(map(), String.t()) :: map()
  def maybe_inject(state, cause) do
    if Map.get(state, :regulation_question_asked, false) do
      state
    else
      Logger.info(
        "[regulation] pain high (#{cause}) — steering toward asking the user ONE question " <>
          "(session: #{Map.get(state, :session_id)})"
      )

      Bus.emit(:system_event, %{
        event: :regulation_question,
        session_id: Map.get(state, :session_id),
        cause: cause
      })

      directive = %{
        role: "system",
        content:
          "[System: #{cause}. Stop checking and ask the user ONE short, concrete question " <>
            "that would resolve this — do not keep verifying, and do not ask more than one.]"
      }

      state
      |> Map.put(:regulation_question_asked, true)
      |> Map.put(:messages, Map.get(state, :messages, []) ++ [directive])
    end
  end
end
