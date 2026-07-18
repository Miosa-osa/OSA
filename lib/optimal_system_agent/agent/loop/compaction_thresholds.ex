defmodule OptimalSystemAgent.Agent.Loop.CompactionThresholds do
  @moduledoc """
  Claude Code-style compaction threshold math (reserve-based, not ratio-based).

  Instead of compacting at a fixed fraction of the context window, thresholds
  are derived by reserving room for the summary output plus fixed safety
  buffers (ported from `services/compact/autoCompact.ts`):

      effective   = context_window - min(output_reserve, 20_000)
      compact_at  = effective - 13_000     # auto-compact fires here
      warn_at     = compact_at - 20_000    # context-low warning band starts
      block_at    = effective - 3_000      # hard blocking limit

  For small local-model windows where the reserve math would collapse
  (compact_at <= 50% of the window), a ratio fallback is used instead:
  compact at 75%, warn at 60%, block at 90%.
  """

  # Reserve for the compact summary output (p99.99 of CC summaries ~= 17.4k).
  @max_output_reserve 20_000
  @autocompact_buffer 13_000
  @warning_buffer 20_000
  @manual_compact_buffer 3_000

  @doc "Context window minus the output reserve for the compact summary."
  @spec effective_window(pos_integer()) :: integer()
  def effective_window(context_window)
      when is_integer(context_window) and context_window > 0 do
    context_window - output_reserve()
  end

  @doc "Token count at which auto-compact fires."
  @spec compact_at(pos_integer()) :: pos_integer()
  def compact_at(cw) when is_integer(cw) and cw > 0 do
    reserve_based = effective_window(cw) - @autocompact_buffer

    if reserve_based > div(cw, 2) do
      reserve_based
    else
      # Small window (local models) — reserve math would fire constantly or
      # never; fall back to a sane ratio.
      trunc(cw * 0.75)
    end
  end

  @doc "Token count at which the context-low warning band starts."
  @spec warn_at(pos_integer()) :: pos_integer()
  def warn_at(cw) when is_integer(cw) and cw > 0 do
    warn = compact_at(cw) - @warning_buffer
    if warn > div(cw, 4), do: warn, else: trunc(cw * 0.60)
  end

  @doc "Hard blocking limit — requests above this should not be attempted."
  @spec block_at(pos_integer()) :: pos_integer()
  def block_at(cw) when is_integer(cw) and cw > 0 do
    block = effective_window(cw) - @manual_compact_buffer
    if block > compact_at(cw), do: block, else: trunc(cw * 0.90)
  end

  @doc "All thresholds as a map (telemetry / TUI warning line)."
  @spec thresholds(pos_integer()) :: map()
  def thresholds(cw) when is_integer(cw) and cw > 0 do
    %{
      effective_window: effective_window(cw),
      compact_at: compact_at(cw),
      warn_at: warn_at(cw),
      block_at: block_at(cw)
    }
  end

  @doc """
  Classify current token usage against the thresholds.

  Returns `%{percent_left, above_warning, above_compact, at_blocking_limit}` —
  the fields the TUI context-low warning consumes (CC
  `calculateTokenWarningState` parity: percent_left is measured against the
  auto-compact threshold, floored at 0).
  """
  @spec warning_state(non_neg_integer(), pos_integer()) :: map()
  def warning_state(tokens, cw)
      when is_integer(tokens) and is_integer(cw) and cw > 0 do
    compact = compact_at(cw)
    percent_left = max(0, round((compact - tokens) / compact * 100))

    %{
      percent_left: percent_left,
      above_warning: tokens >= warn_at(cw),
      above_compact: tokens >= compact,
      at_blocking_limit: tokens >= block_at(cw)
    }
  end

  defp output_reserve do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :compaction_output_reserve,
        @max_output_reserve
      )

    if is_integer(configured) and configured > 0,
      do: min(configured, @max_output_reserve),
      else: @max_output_reserve
  end
end
