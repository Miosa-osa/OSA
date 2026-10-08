defmodule OptimalSystemAgent.Agent.Loop.CompactionThresholds do
  @moduledoc """
  Compaction threshold math (reserve-based, not ratio-based).

  Instead of compacting at a fixed fraction of the context window, thresholds
  are derived by reserving room for the summary output plus fixed safety
  buffers:

      effective   = context_window - min(output_reserve, 20_000)
      compact_at  = min(effective - 13_000, 0.85 * window)  # auto-compact fires here
      warn_at     = compact_at - 20_000                      # context-low band starts
      block_at    = effective - 3_000                        # hard blocking limit

  For small local-model windows where the reserve math would collapse
  (compact_at <= 50% of the window), a ratio fallback is used instead:
  compact at 75%, warn at 60%, block at 90%.

  ## The model's whole window is live

  Every threshold is computed from `operative_window/2`, which is the model's
  real window unless the operator caps it. A 1,048,576-token model compacts at
  ~891k (85%), a 200k model at 167k, a 128k model at 95k.

  The 85% share is what keeps compaction reachable on a big window. The reserve
  subtraction alone is absolute, so on 1M it would put `compact_at` at 96.7% of
  the window (MEASURED earlier on `glm-5.2:cloud`: 967,000), leaving almost no
  room for the summarization round-trip. 15% of the window is that room, and it
  grows with the window instead of staying a fixed 33k.

  ### History: the 200k ceiling, and why it is gone

  From v1.0.201 to v1.0.205 every model was clamped to a 200k operative window
  (compact at 167k), on measured latency: on `glm-5.2:cloud` provider
  time-to-first-byte grew from ~1-2s at ~23k tokens to 4.4-13.9s at ~300k,
  because the whole history is re-read on every turn. The clamp also made the
  status bar divide by 200k, so a 1M model at 159k read "80% ctx" with "4%
  remaining" (reported live on `deepseek-v4.1-flash:cloud`). The operator
  chose the full window: a 1M model is selected for its 1M. Latency still grows
  with history, so the cap remains one setting away:

    * `OSA_CONTEXT_CEILING` / `config :optimal_system_agent,
      compaction_context_ceiling: n` - an absolute cap for every model.
    * `OSA_CONTEXT_CEILING_SHARE` / `compaction_context_ceiling_share: f` - a
      share of each model's window (floored at 200k).

  v1.0.205 also tightened the ceiling to 100k for any model whose catalog input
  price was at or below $1/M, as a proxy for "small model". Price is not size:
  it would have put a 763B, 1M-window model on a 100k budget. It is removed.
  """

  # Reserve for the compact summary output (p99.99 of summaries ~= 17.4k).
  @max_output_reserve 20_000
  @autocompact_buffer 13_000
  @warning_buffer 20_000
  @manual_compact_buffer 3_000

  # The window assumed when a model's real window is unknown (see
  # `fallback_window/0`), and the floor under a configured ceiling share.
  @context_ceiling 200_000

  @doc """
  The window all threshold math runs against: the model's real window, unless
  the operator configured a cap (see the moduledoc).

  `model` is accepted for call-site symmetry with every other threshold
  function and is not currently consulted. Idempotent, so composing it with
  itself (as `compact_at/2` does via `effective_window/2`) is safe.
  """
  @spec operative_window(pos_integer(), String.t() | nil) :: pos_integer()
  def operative_window(context_window, model \\ nil)

  def operative_window(context_window, _model)
      when is_integer(context_window) and context_window > 0 do
    min(context_window, configured_ceiling(context_window))
  end

  defp configured_ceiling(context_window) do
    case Application.get_env(:optimal_system_agent, :compaction_context_ceiling) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case ceiling_share() do
          nil -> context_window
          share -> max(@context_ceiling, trunc(context_window * share))
        end
    end
  end

  # Share of the operative window at which auto-compact fires. 0.85 leaves 15%
  # for the summarization round-trip and the model's output - proportional, so
  # the headroom grows with the window instead of staying a fixed 33k that is
  # 26% of a 128k model and 3.3% of a 1M one.
  @compact_at_share 0.85

  defp compact_at_share do
    case Application.get_env(:optimal_system_agent, :compaction_compact_at_share) do
      f when is_float(f) and f > 0.0 and f < 1.0 -> f
      _ -> @compact_at_share
    end
  end

  # nil when unset: the model's whole window is operative.
  defp ceiling_share do
    case Application.get_env(:optimal_system_agent, :compaction_context_ceiling_share) do
      f when is_float(f) and f > 0.0 and f <= 1.0 -> f
      _ -> nil
    end
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
  @spec effective_window(pos_integer(), String.t() | nil) :: integer()
  def effective_window(context_window, model \\ nil)

  def effective_window(context_window, model)
      when is_integer(context_window) and context_window > 0 do
    operative_window(context_window, model) - output_reserve()
  end

  @doc "Token count at which auto-compact fires. `model` — see moduledoc."
  @spec compact_at(pos_integer(), String.t() | nil) :: pos_integer()
  def compact_at(cw, model \\ nil)

  def compact_at(cw, model) when is_integer(cw) and cw > 0 do
    cw = operative_window(cw, model)

    # Subtract the reserve directly rather than via `effective_window/1`, which
    # would clamp a value that is already clamped. A flat ceiling made
    # `operative_window/1` idempotent so the double application was invisible; a
    # ceiling that is a SHARE of the window is not idempotent, and applying it
    # twice shrank a 500k model to 200k (compact_at 167,000 instead of 217,000)
    # — silently reproducing the exact flat-constant behaviour this change
    # exists to remove.
    # Two bounds, whichever binds first:
    #
    #   * the reserve math — leave room for the summary round-trip and output.
    #     It is an ABSOLUTE subtraction, so on a small window it dominates
    #     (128k -> 95k) and on a large one it barely bites (1M -> 967k, i.e.
    #     96.7%, which is why compaction was effectively unreachable there).
    #   * a share of the window — proportional, so it is the one that binds on
    #     big models and expresses the rule an operator actually reasons about:
    #     "I get most of my window, then it compacts."
    #
    # Both are per-model by construction. Every model at or below ~235k is
    # unchanged, because the reserve subtraction is still the smaller number.
    reserve_based =
      min(
        cw - output_reserve() - @autocompact_buffer,
        trunc(cw * compact_at_share())
      )

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
  @spec warn_at(pos_integer(), String.t() | nil) :: pos_integer()
  def warn_at(cw, model \\ nil)

  def warn_at(cw, model) when is_integer(cw) and cw > 0 do
    cw = operative_window(cw, model)
    compact = compact_at(cw, model)
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
  @spec block_at(pos_integer(), String.t() | nil) :: pos_integer()
  def block_at(cw, model \\ nil)

  def block_at(cw, model) when is_integer(cw) and cw > 0 do
    cw = operative_window(cw, model)
    compact = compact_at(cw, model)
    reserve_based = effective_window(cw, model) - @manual_compact_buffer
    preferred = if reserve_based > compact, do: reserve_based, else: trunc(cw * 0.90)
    max(preferred, compact + 1)
  end

  @doc "All thresholds as a map (telemetry / TUI warning line). `model` — see moduledoc."
  @spec thresholds(pos_integer(), String.t() | nil) :: map()
  def thresholds(cw, model \\ nil)

  def thresholds(cw, model) when is_integer(cw) and cw > 0 do
    %{
      context_window: cw,
      operative_window: operative_window(cw, model),
      clamped?: operative_window(cw, model) < cw,
      effective_window: effective_window(cw, model),
      compact_at: compact_at(cw, model),
      warn_at: warn_at(cw, model),
      block_at: block_at(cw, model)
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
  @spec used_percent(non_neg_integer(), pos_integer(), String.t() | nil) :: float()
  def used_percent(tokens, cw, model \\ nil)

  def used_percent(tokens, cw, model)
      when is_integer(tokens) and tokens >= 0 and is_integer(cw) and cw > 0 do
    # Clamped denominator, so the meter and the compaction trigger agree: on a
    # 1M-window model the bar reads ~93% when auto-compact fires, not 17%.
    cw = operative_window(cw, model)

    denom =
      case effective_window(cw, model) do
        eff when eff > 0 -> eff
        _ -> cw
      end

    Float.round(min(tokens / denom * 100, 100.0), 1)
  end

  def used_percent(_, _, _), do: 0.0

  @doc """
  Classify current token usage against the thresholds.

  Returns `%{percent_left, above_warning, above_compact, at_blocking_limit}` —
  the fields the TUI context-low warning consumes (CC
  `calculateTokenWarningState` parity: percent_left is measured against the
  auto-compact threshold, floored at 0). `model` — see moduledoc.
  """
  @spec warning_state(non_neg_integer(), pos_integer(), String.t() | nil) :: map()
  def warning_state(tokens, cw, model \\ nil)

  def warning_state(tokens, cw, model)
      when is_integer(tokens) and is_integer(cw) and cw > 0 do
    compact = compact_at(cw, model)
    percent_left = max(0, round((compact - tokens) / compact * 100))

    %{
      percent_left: percent_left,
      above_warning: tokens >= warn_at(cw, model),
      above_compact: tokens >= compact,
      at_blocking_limit: tokens >= block_at(cw, model)
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
