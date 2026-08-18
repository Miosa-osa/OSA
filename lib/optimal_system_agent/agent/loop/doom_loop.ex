defmodule OptimalSystemAgent.Agent.Loop.DoomLoop do
  require Logger

  alias OptimalSystemAgent.Events.Bus

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Stall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnly
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature

  # Absolute session tool-call backstop.
  #
  # Sizing: this must not be reachable by a run that is merely WORKING, only by
  # one that is running away. A sustained agent averages roughly 10-30 tool
  # calls a minute, so a 12-hour unattended run lands in the 7k-20k range. The
  # previous 2000 sat *inside* that band - it halted a healthy overnight run
  # after a few hours and reported it as a safety stop, which is the worst
  # possible framing for "you were working too long".
  #
  # 25_000 clears a 12-hour run with headroom. Runaway is caught by the pattern
  # detectors (IdenticalCall, Stall, FailureSignature, ReasoningOnly,
  # Escalation), which fire in seconds on a spinning loop and do not care how
  # long the session has been alive. This count is only the last-resort net
  # under all of them.
  #
  # Order matters: the environment variable wins, because an unattended run that
  # trips the cap at 3am cannot be rescued by editing application config.
  @default_max_tool_calls 25_000

  @doc false
  def max_total_tool_calls do
    case env_max_tool_calls() do
      nil ->
        Application.get_env(
          :optimal_system_agent,
          :doom_loop_max_calls,
          @default_max_tool_calls
        )

      n ->
        n
    end
  end

  # `OSA_MAX_TOOL_CALLS`. A junk or non-positive value is ignored rather than
  # obeyed: silently running with a cap of 0 would halt the first tool call.
  defp env_max_tool_calls do
    with value when is_binary(value) <- System.get_env("OSA_MAX_TOOL_CALLS"),
         {n, ""} <- Integer.parse(String.trim(value)),
         true <- n > 0 do
      n
    else
      _ -> nil
    end
  end

  @warn_threshold_pct 0.80

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
    warn_at = trunc(max_calls * @warn_threshold_pct)

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
        new_total >= max_calls ->
          handle_call_cap_exceeded(new_total, max_calls, state)

        new_total >= warn_at and new_total - call_count < warn_at ->
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
