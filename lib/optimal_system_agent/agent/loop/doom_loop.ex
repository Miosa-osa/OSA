defmodule OptimalSystemAgent.Agent.Loop.DoomLoop do
  require Logger

  alias OptimalSystemAgent.Events.Bus

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Stall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnly
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature

  # Declared before first use: a module attribute read above its definition is
  # `nil`, which turned the warning-threshold arithmetic into `max * nil`.
  @warn_threshold_pct 0.80

  # Session tool-call ceiling. UNLIMITED unless an operator asks for a limit.
  #
  # An absolute count cannot distinguish "working for a long time" from "stuck".
  # Whatever number is chosen, a healthy unattended run eventually reaches it and
  # is halted for the crime of still going - and the halt is reported as a safety
  # stop, which reads as though the agent misbehaved. 2000 halted a normal run
  # after a few hours; 25_000 only moves the same wall further out.
  #
  # Runaway is a SHAPE, not a volume: the same call repeated, no forward
  # progress, the same failure signature again and again, reasoning with no
  # tool calls. `IdenticalCall`, `Stall`, `FailureSignature`, `ReasoningOnly`
  # and `Escalation` all read that shape directly and halt within seconds,
  # regardless of session age. They are the stop condition. A counter is not.
  #
  # A limit is still available for callers that genuinely want one - CI jobs,
  # evals, cost-bounded sandboxes - via `OSA_MAX_TOOL_CALLS` (which wins, since
  # an unattended run cannot be rescued by editing application config) or
  # `config :optimal_system_agent, :doom_loop_max_calls, <int>`.
  # A very large finite number rather than `:infinity`. Codex, for reference,
  # ships no tool-call ceiling at all. A finite value keeps the cap printable,
  # comparable and assertable, and still stops a true runaway eventually rather
  # than burning forever; at a sustained 30 calls a minute this is roughly 23
  # days of continuous work, so no real session reaches it.
  @unbounded_tool_calls 1_000_000

  @doc false
  def max_total_tool_calls do
    case env_max_tool_calls() do
      nil ->
        Application.get_env(:optimal_system_agent, :doom_loop_max_calls, @unbounded_tool_calls)

      value ->
        value
    end
  end

  # `OSA_MAX_TOOL_CALLS`. Accepts a positive integer, or an explicit word for
  # "no limit". Junk and non-positive values are ignored rather than obeyed:
  # obeying a cap of 0 would halt the first tool call of the run.
  defp env_max_tool_calls do
    case System.get_env("OSA_MAX_TOOL_CALLS") do
      nil ->
        nil

      value ->
        case value |> String.trim() |> String.downcase() do
          unlimited when unlimited in ~w(unlimited none off infinity infinite) ->
            :infinity

          trimmed ->
            case Integer.parse(trimmed) do
              {n, ""} when n > 0 -> n
              _ -> nil
            end
        end
    end
  end

  # Explicit rather than leaning on Elixir term ordering, under which
  # `5 >= :infinity` happens to be false. True, but accidental.
  defp call_cap_reached?(_total, :infinity), do: false
  defp call_cap_reached?(total, max) when is_integer(max), do: total >= max
  defp call_cap_reached?(_total, _max), do: false

  # No ceiling means no "approaching the ceiling" to warn about.
  @doc false
  def warn_threshold_for(max), do: warn_threshold(max)

  defp warn_threshold(:infinity), do: nil
  defp warn_threshold(max) when is_integer(max), do: trunc(max * @warn_threshold_pct)
  defp warn_threshold(_), do: nil

  @moduledoc """
  Doom loop detection for the agent loop — a coordinator over independent
  detectors.

  `check/3` is the single public entry point. It threads `state` through each
  detector in turn (short-circuiting on the first hard halt) and owns only the
  absolute call-cap safety net directly. Each detector lives in its own module
  and communicates through explicit `state` — never the process dictionary:

    * `DoomLoop.IdenticalCall`     — same tool+args repeated back-to-back
    * `DoomLoop.Stall`             — no forward progress over a window
    * `DoomLoop.ReasoningOnly`     — reasoning-only / turn-errored spin, zero tool calls
    * `DoomLoop.FailureSignature`  — same tool+error signature repeats
    * `DoomLoop.Escalation`        — shared graded "nudge before halt" sequence

  Two independent safety mechanisms guard against runaway tool execution:

  1. **Signature-based detection** (primary, `DoomLoop.FailureSignature`) —
     detects when the same tool+error signature repeats 3+ consecutive times
     across iterations and halts execution to avoid wasting tokens on a stuck
     task.

     - Builds per-tool failure signatures from each iteration's results
     - Accumulates signatures in a sliding window of 20 entries
     - Resets the error-based streak when any tool succeeds cleanly
     - Fires when any single signature appears 3+ times in the window

  2. **Absolute call cap** (secondary safety net) — independently of the
     signature check, halts the session once total tool calls in the session
     exceed `@max_total_tool_calls`. This prevents a pathological worst-case
     where many *different* failure signatures accumulate without repeating
     enough to trigger the primary check.

     Configurable via: `config :optimal_system_agent, :doom_loop_max_calls, 100`
     A warning is logged at 80% of the limit.
  """

  @doc """
  Check tool results for a repeating failure pattern.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  @spec check(list(), list(), map()) ::
          {:ok, map()} | {:halt, String.t(), map()}
  def check(results, tool_calls, state) do
    # At most one graded directive is injected per invocation; reset the
    # per-tick guard so multiple approaching signals don't stack directives.
    # Defensive: the delegate/orchestrate path builds a loop state that may omit
    # the doom-loop counters, so use Map.put (not %{state | ...}, which raises
    # KeyError when the key is absent). Mirrors the Map.get/Map.put style the
    # sub-detectors (stall/identical_call/escalation) already use.
    state = Map.put(state, :escalated_this_tick, false)

    # --- Absolute call counter (secondary safety net) ---
    call_count = length(tool_calls)
    new_total = Map.get(state, :total_tool_calls, 0) + call_count
    state = Map.put(state, :total_tool_calls, new_total)

    max_calls = max_total_tool_calls()
    warn_at = warn_threshold(max_calls)

    # --- Identical-call detection ---
    # Catches the model spamming the same tool+args back-to-back even when the
    # calls succeed. The signature-based check below only catches repeated
    # FAILURES; this catches repeated USELESS SUCCESSES.
    # `results` is threaded in because the windowed-repeat rule keys on the
    # RESULT bytes, not just the arguments: a repeat that returns something
    # different is progress (read->edit->read, test->fix->test) and must not
    # count toward a halt. Without the results it can only fall back to the
    # consecutive-streak rule.
    with {:ok, state} <- IdenticalCall.check(results, tool_calls, state),
         # --- Stall detection ---
         # No newly-distinct tool and no file write/edit over the last N calls.
         {:ok, state} <- Stall.check(tool_calls, state),
         # --- Reasoning-only / turn-errored detection ---
         # Catches a model spinning in thought with zero tool calls (and/or a
         # turn the caller flags as errored via state.turn_errored) — a loop
         # shape none of the tool-call-keyed detectors above can see. Ordered
         # BEFORE FailureSignature per spec: an empty `tool_calls`/`results`
         # this turn would otherwise just fall through FailureSignature as a
         # silent no-op, wasting a whole detection pass.
         {:ok, state} <- ReasoningOnly.check(tool_calls, state) do
      cond do
        call_cap_reached?(new_total, max_calls) ->
          handle_call_cap_exceeded(new_total, max_calls, state)

        is_integer(warn_at) and new_total >= warn_at and new_total - call_count < warn_at ->
          Logger.warning(
            "[doom] Approaching tool call limit (#{new_total}/#{max_calls}) " <>
              "(session: #{state.session_id})"
          )

          FailureSignature.check(results, tool_calls, state)

        true ->
          FailureSignature.check(results, tool_calls, state)
      end
    else
      {:halt, _, _} = halted -> halted
    end
  end

  # --- Private ---

  defp handle_call_cap_exceeded(total, max_calls, state) do
    cap_message =
      """
      I've reached the session tool call limit (#{total}/#{max_calls}) and am stopping to avoid runaway execution.

      This limit exists as a safety net independent of error-pattern detection.

      How to proceed:
      - If the task is incomplete, start a new session and continue from where you left off.
      - To raise the limit for a long unattended run, set `OSA_MAX_TOOL_CALLS` (for
        example `OSA_MAX_TOOL_CALLS=50000`) before starting OSA, or set
        `doom_loop_max_calls` in application config.
      """
      |> String.trim()

    Logger.warning(
      "[loop] Tool call cap exceeded: #{total}/#{max_calls} (session: #{state.session_id})"
    )

    Bus.emit(:system_event, %{
      event: :tool_call_cap_exceeded,
      session_id: state.session_id,
      total_tool_calls: total,
      max_tool_calls: max_calls
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :tool_call_cap_exceeded,
         session_id: state.session_id,
         total_tool_calls: total,
         max_tool_calls: max_calls
       }}
    )

    {:halt, cap_message, state}
  end
end
