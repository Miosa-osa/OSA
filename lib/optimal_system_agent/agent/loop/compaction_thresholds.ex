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

  ## The absolute ceiling

  Every threshold above is a function of the model's window with no upper
  bound, so a bigger window buys a proportionally bigger uncompacted history.
  MEASURED on `glm-5.2:cloud` (1M window): `compact_at` came out at **967,000**
  and `warn_at` at **947,000**. Nothing — not full compaction, not
  microcompaction, not `Memory.Flush` — could engage below 947k, and a 15-turn
  working session peaked at 37,750 tokens, 3.9% of the trigger. Compaction was
  not merely late on large-context models; it was unreachable.

  That is not a cosmetic bound. The request grows LINEARLY with the transcript
  (measured: +754 tokens/turn) and every request re-sends the whole thing, so
  cumulative session input is quadratic in turn count. Compaction is the only
  brake on that term, and against a harness that compacts near 170k the
  accumulated cost runs roughly `(967/167)^2` ≈ 33x higher.

  So `operative_window/1` clamps the window every threshold is computed from:

      operative = min(context_window, @context_ceiling)

  Clamping the WINDOW rather than each threshold keeps the whole ladder
  internally consistent — `warn_at < compact_at < block_at` still hold by the
  same construction, and `used_percent/2` still reads ~93% exactly when
  auto-compact fires, because its denominator is clamped too.

  ### Why 200,000

  * `compact_at(200_000)` = **167,000**, which sits in the 170k band
    `docs/research/what-harnesses-benchmark.md` records for competing harnesses,
    and comfortably above the 100K OpenAI uses — we are not adopting the most
    aggressive number in the field, we are rejoining it.
  * It is a no-op for every model at or below a 200k window. Claude's 200k,
    `glm-4.7:cloud`'s 202,752 and every 128k model keep their current
    thresholds exactly. The clamp only binds on the >200k models where the
    measurement showed it was needed, so this cannot regress a configuration
    that was working.
  * It leaves 33,000 tokens of headroom between `compact_at` and the clamped
    window for the summarization round-trip, which is the same headroom the
    reserve math already assumed.

  Override with `config :optimal_system_agent, compaction_context_ceiling: n`.
  Setting it above a model's real window disables the clamp for that model.
  """

  # Reserve for the compact summary output (p99.99 of CC summaries ~= 17.4k).
  @max_output_reserve 20_000
  @autocompact_buffer 13_000
  @warning_buffer 20_000
  @manual_compact_buffer 3_000

  # Absolute ceiling on the window every threshold is derived from. See the
  # "Why 200,000" section above; this is the single number that decides how
  # much transcript OSA will carry before it compacts, on any model.
  @context_ceiling 200_000

  @doc """
  The window all threshold math runs against: `min(context_window, ceiling)`.

  Idempotent, so composing it with itself (as `compact_at/1` does via
  `effective_window/1`) is safe.
  """
  @spec operative_window(pos_integer()) :: pos_integer()
  def operative_window(context_window)
      when is_integer(context_window) and context_window > 0 do
    min(context_window, context_ceiling())
  end

  @doc """
  The window assumed when the real one is UNKNOWN.

  Returns the ceiling itself, which makes the fallback exactly correct for
  every model whose real window is at or above it — the clamp would have
  produced the same thresholds anyway — and bounded-wrong, never unbounded,
  below it. See `Loop.ContextWindow` for why "unknown" used to mean "never
  compact" and why that stopped being the safer answer once the ceiling
  existed.
  """
  @spec fallback_window() :: pos_integer()
  def fallback_window, do: context_ceiling()

  @doc "Context window minus the output reserve for the compact summary."
  @spec effective_window(pos_integer()) :: integer()
  def effective_window(context_window)
      when is_integer(context_window) and context_window > 0 do
    operative_window(context_window) - output_reserve()
  end

  @doc "Token count at which auto-compact fires."
  @spec compact_at(pos_integer()) :: pos_integer()
  def compact_at(cw) when is_integer(cw) and cw > 0 do
    cw = operative_window(cw)
    reserve_based = effective_window(cw) - @autocompact_buffer

    if reserve_based > div(cw, 2) do
      reserve_based
    else
      # Small window (local models) — reserve math would fire constantly or
      # never; fall back to a sane ratio.
      trunc(cw * 0.75)
    end
  end

  @doc """
  Token count at which the context-low warning band starts.

  The band between `warn_at` and `compact_at` is not decoration: it is the only
  place `should_microcompact?/2` and `Memory.Flush.flush_at/1` can fire. Both
  guard on `tokens >= warn_at and tokens < compact_at`, so an inverted or
  one-token-wide band silently disables them.

  It used to invert. For windows in `(66_000, 70_667]` the reserve path won for
  `compact_at` while `warn_at` fell through to its `0.60 * cw` fallback, and
  `0.60 * cw > cw - 33_000` across that whole range — at `cw = 70_000`,
  `warn_at` came out at 42,000 against a `compact_at` of 37,000. Nothing warned:
  `severity_for/2`'s ordered `cond` masks the inversion, the microcompaction
  guard just became unsatisfiable, and the memory flush clamped itself to a band
  one token wide. That range is reachable through a configured local `num_ctx`.

  So the fallback is now a *preference*, not a licence to exceed `compact_at`.
  The result is clamped to leave a band at least a quarter of `compact_at` wide,
  which makes the ordering `warn_at < compact_at` structural rather than
  something the two formulas happen to agree on.
  """
  @spec warn_at(pos_integer()) :: pos_integer()
  def warn_at(cw) when is_integer(cw) and cw > 0 do
    cw = operative_window(cw)
    compact = compact_at(cw)
    reserve_based = compact - @warning_buffer

    preferred =
      if reserve_based > div(cw, 4) do
        reserve_based
      else
        # Small window (local models) — the reserve math would collapse.
        trunc(cw * 0.60)
      end

    min(preferred, compact - min(@warning_buffer, div(compact, 4)))
  end

  @doc """
  Hard blocking limit — requests above this should not be attempted.

  Clamped above `compact_at` for the same reason `warn_at/1` is clamped below
  it: a blocking limit at or under the compaction threshold would refuse the
  very request compaction just made room for.
  """
  @spec block_at(pos_integer()) :: pos_integer()
  def block_at(cw) when is_integer(cw) and cw > 0 do
    cw = operative_window(cw)
    compact = compact_at(cw)
    reserve_based = effective_window(cw) - @manual_compact_buffer
    preferred = if reserve_based > compact, do: reserve_based, else: trunc(cw * 0.90)
    max(preferred, compact + 1)
  end

  @doc "All thresholds as a map (telemetry / TUI warning line)."
  @spec thresholds(pos_integer()) :: map()
  def thresholds(cw) when is_integer(cw) and cw > 0 do
    %{
      context_window: cw,
      operative_window: operative_window(cw),
      clamped?: operative_window(cw) < cw,
      effective_window: effective_window(cw),
      compact_at: compact_at(cw),
      warn_at: warn_at(cw),
      block_at: block_at(cw)
    }
  end

  @doc """
  Context used as a percent of the *usable* (effective) window — the number the
  status bar shows.

  Claude Code parity: the displayed "N% context used" is measured against the
  effective window (`context_window - output_reserve`), not the raw model window,
  so the meter reads ~93% exactly when auto-compact fires (`compact_at` sits one
  `@autocompact_buffer` below the effective window). Returns a float 0.0..100.0,
  clamped so a transient over-count never renders above 100%.

  For tiny local windows where the reserve math collapses (effective_window would
  be zero or negative), the raw window is used as the denominator instead, which
  keeps the meter aligned with the ratio-based compaction fallback (compact at
  75%).
  """
  @spec used_percent(non_neg_integer(), pos_integer()) :: float()
  def used_percent(tokens, cw)
      when is_integer(tokens) and tokens >= 0 and is_integer(cw) and cw > 0 do
    # Clamped denominator, so the meter and the compaction trigger agree: on a
    # 1M-window model the bar reads ~93% when auto-compact fires, not 17%.
    cw = operative_window(cw)

    denom =
      case effective_window(cw) do
        eff when eff > 0 -> eff
        _ -> cw
      end

    Float.round(min(tokens / denom * 100, 100.0), 1)
  end

  def used_percent(_, _), do: 0.0

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

  defp context_ceiling do
    case Application.get_env(
           :optimal_system_agent,
           :compaction_context_ceiling,
           @context_ceiling
         ) do
      n when is_integer(n) and n > 0 -> n
      _ -> @context_ceiling
    end
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
