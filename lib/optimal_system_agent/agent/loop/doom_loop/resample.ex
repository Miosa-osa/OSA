defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.Resample do
  @moduledoc """
  Doom-loop *resample* recovery — the remedy that pairs with detection.

  OSA's `DoomLoop` detectors (`IdenticalCall`, `Stall`, `FailureSignature`)
  already *detect* a loop and return `{:halt, message, state}`. Historically the
  only remedy was to surface that message and end the turn. But for a
  repetition / reasoning-only loop the fix is usually not to *wait* — it is to
  *re-roll*: discard the offending assistant response and re-sample the turn.
  A model at temperature > 0 frequently produces a genuinely different (and
  unstuck) response on the retry.

  This module owns that decision. When a detector halts, `handle/4`:

    1. If resampling is disabled → returns the halt unchanged (old behavior).
    2. If the per-turn resample budget is exhausted → returns the halt
       unchanged, falling back to the existing surface/permission-prompt/abort
       behavior.
    3. Otherwise → **discards the offending assistant response** (by rewinding
       to `snapshot.messages`, which predates that response), appends a short
       break-the-loop directive, and re-invokes the loop via `run_fun`, up to
       `max_retries` times with a small/zero backoff (re-rolling is the remedy,
       not waiting).

  Configurable via a keyword list (grok's `DoomLoopRecoverySettings`):

      config :optimal_system_agent, :doom_loop_resample,
        enabled: true,      # default true
        max_retries: 2,     # resample budget per turn
        backoff_ms: 0,      # near-zero: re-rolling is the fix, not waiting
        threshold: 4        # identical-call repeats before a loop is declared

  The resample count is tracked on the threaded `state` as `:doom_resamples`
  (Map-based, defensive like the other doom counters) and is reset to 0 by the
  loop on any clean `{:ok, state}` — so the budget bounds *consecutive*
  recovery attempts, not the session lifetime.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.TerminalSource
  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Events.Bus

  @default_max_retries 2
  @default_backoff_ms 0
  @default_threshold 4

  @doc """
  Decide whether to resample after a detector halted, or fall back to the halt.

  * `doom_message` / `halted_state` — the `{:halt, message, state}` a detector
    returned; these are what we return unchanged when resampling is disabled or
    exhausted.
  * `snapshot` — the loop state as it was *before* the offending assistant
    response was appended this turn. Rewinding to it is what "discards the
    looping response".
  * `run_fun` — arity-1 function that re-runs the loop (`&ReactLoop.run/1`).

  Returns `{response_string, state}` in every case (either the re-rolled turn's
  result, or the original halt tuple's `{message, state}`).
  """
  @spec handle(String.t(), map(), map(), (map() -> {String.t(), map()})) ::
          {String.t(), map()}
  def handle(doom_message, halted_state, snapshot, run_fun) when is_function(run_fun, 1) do
    used = Map.get(snapshot, :doom_resamples, 0)
    max = max_retries()
    sid = Map.get(snapshot, :session_id)

    cond do
      not enabled?() ->
        # The halt text is the GUARD talking about the loop, not the model
        # answering the user. Marked so it cannot be rendered as the answer.
        TerminalSource.halt(doom_message, halted_state, :guard)

      used >= max ->
        Logger.warning(
          "[doom] Resample budget exhausted (#{used}/#{max}) — falling back to halt " <>
            "(session: #{sid})"
        )

        Bus.emit(:system_event, %{
          event: :doom_loop_resample,
          session_id: sid,
          outcome: :exhausted,
          attempt: used,
          max_retries: max
        })

        # The halt text is the GUARD talking about the loop, not the model
        # answering the user. Marked so it cannot be rendered as the answer.
        TerminalSource.halt(doom_message, halted_state, :guard)

      true ->
        attempt = used + 1

        Logger.warning(
          "[doom] Doom loop detected — resampling turn (attempt #{attempt}/#{max}); " <>
            "discarding offending response (session: #{sid})"
        )

        Bus.emit(:system_event, %{
          event: :doom_loop_resample,
          session_id: sid,
          outcome: :resampling,
          attempt: attempt,
          max_retries: max
        })

        maybe_backoff()
        retry_state = build_retry_state(snapshot, attempt)

        # Fast mode is the lowest reasoning tier. Re-running the exact failed
        # decision at the same tier repeatedly reproduced the same tool loop in
        # production, exhausting both retries. Recovery is intentionally a
        # different operating point: raise only THIS loop process to medium for
        # the retry, which also disables FastPath's narrowed tool set, then
        # restore the user's global fast setting in `after`.
        if Effort.current() == :fast do
          Effort.with_process_override(:medium, fn -> run_fun.(retry_state) end)
        else
          run_fun.(retry_state)
        end
    end
  end

  # --- Config ---

  @doc "Whether doom-loop resample recovery is enabled (default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc "Resample budget per turn (default #{@default_max_retries})."
  @spec max_retries() :: non_neg_integer()
  def max_retries, do: Keyword.get(config(), :max_retries, @default_max_retries)

  @doc "Backoff between resamples in ms (default #{@default_backoff_ms} — re-rolling is the fix)."
  @spec backoff_ms() :: non_neg_integer()
  def backoff_ms, do: Keyword.get(config(), :backoff_ms, @default_backoff_ms)

  @doc """
  Identical-call repeat threshold before a loop is declared (default
  #{@default_threshold}). Read by `DoomLoop.IdenticalCall` so detection
  sensitivity and the resample remedy share one settings block, matching grok's
  combined `DoomLoopRecoverySettings`.
  """
  @spec threshold() :: pos_integer()
  def threshold, do: Keyword.get(config(), :threshold, @default_threshold)

  defp config, do: Application.get_env(:optimal_system_agent, :doom_loop_resample, [])

  # --- Private ---

  # Rewind to the pre-response snapshot (discarding the offending assistant
  # message + its tool results), record the attempt, and append a light directive
  # so the re-roll is nudged toward a genuinely different action rather than
  # reproducing the exact loop at the same temperature.
  defp build_retry_state(snapshot, attempt) do
    nudge = %{
      role: "system",
      content:
        "[System: your previous response was discarded because it repeated without making " <>
          "progress (a loop was detected). Do NOT repeat the same tool call or the same " <>
          "reasoning — take a concretely different approach on this attempt.]"
    }

    snapshot
    |> Map.put(:doom_resamples, attempt)
    |> Map.put(:messages, Map.get(snapshot, :messages, []) ++ [nudge])
  end

  defp maybe_backoff do
    case backoff_ms() do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end
end
