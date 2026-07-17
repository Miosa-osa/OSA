defmodule OptimalSystemAgent.Agent.Loop.DoomLoop do
  require Logger

  alias OptimalSystemAgent.Events.Bus

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Stall
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature

  # Runtime-tunable (not compile_env) so the absolute tool-call cap can be
  # raised for an hours-long autonomous run without recompiling. Default raised
  # to 2000 — a genuine backstop just above realistic multi-hour volume, not a
  # premature stop at 100.
  defp max_total_tool_calls,
    do: Application.get_env(:optimal_system_agent, :doom_loop_max_calls, 2000)

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
    with {:ok, state} <- IdenticalCall.check(tool_calls, state),
         # --- Stall detection ---
         # No newly-distinct tool and no file write/edit over the last N calls.
         {:ok, state} <- Stall.check(tool_calls, state) do
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
      - If you need a higher limit, adjust `doom_loop_max_calls` in your application config.
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
