defmodule OptimalSystemAgent.Agent.Loop.Regulation do
  @moduledoc """
  The turn's regulation core — single entry point.

  Wired into `ReactLoop.continue_after_tools/4` right after `DoomLoop.check/3`
  returns `{:ok, state}` (a halt from `DoomLoop` already ends the turn; there
  is nothing left for this module to regulate). Runs, in order:

    1. `Regulation.Surprise` — cheap post-hoc surprise detection over this
       iteration's results (item 11), folded onto `state` before scoring so a
       surprise that just happened counts toward THIS iteration's pain.
    2. `Regulation.Signals.collect/3` — ONE read of every turn-level signal,
       including the approval-wait accumulator (which resets on read — see
       `PainChannel` — so this must happen exactly once per iteration).
    3. `Regulation.Homeostat.regulate/4` — the four essential variables, each
       corrected through an existing mechanism (item 6).
    4. `Regulation.Pain.evaluate/3` — the unified score, surfaced to the user,
       and the continue/steer/pause decision (item 1 + item 14).

  Returns `{:ok, state}` to continue exactly like `DoomLoop.check/3`, or
  `{:halt, message, state}` — which the caller marks `:control` via
  `TerminalSource`, NOT `Resample`: a pain-triggered pause hands the turn back
  to the user, it does not re-roll the last response.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.Regulation.Homeostat
  alias OptimalSystemAgent.Agent.Loop.Regulation.Pain
  alias OptimalSystemAgent.Agent.Loop.Regulation.Signals
  alias OptimalSystemAgent.Agent.Loop.Regulation.Surprise

  @spec regulate(list(), list(), map()) :: {:ok, map()} | {:halt, String.t(), map()}
  def regulate(results, tool_calls, state) do
    state = Surprise.check(results, tool_calls, state)
    signals = Signals.collect(results, tool_calls, state)
    {state, homeostat_report} = Homeostat.regulate(results, tool_calls, state, signals)
    Pain.evaluate(state, signals, homeostat_report)
  rescue
    e ->
      Logger.error(
        "[regulation] regulate/3 raised — continuing without regulating this iteration: " <>
          Exception.message(e)
      )

      {:ok, state}
  end
end
