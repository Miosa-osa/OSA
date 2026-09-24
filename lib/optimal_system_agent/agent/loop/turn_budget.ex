defmodule OptimalSystemAgent.Agent.Loop.TurnBudget do
  @moduledoc """
  Per-turn pacing budget: what is left THIS turn, in a form the model can use
  to pace itself and wrap up gracefully instead of running until a hard stop.

  ## Why

  A model with no visibility into its remaining budget tends to either stop
  too early (padding a short task with unnecessary caution) or run until it
  is cut off mid-thought by `ReactLoop`'s iteration ceiling. Giving it a
  compact countdown -- steps used/remaining, output tokens used/remaining
  against a turn target, and elapsed time -- lets it self-pace and produce a
  clean handoff when the budget is nearly spent, instead of a truncated one.

  ## Placement is the whole point

  This note is appended to the OUTBOUND MESSAGE LIST, not built into
  `Agent.Context`. `Context.build/1`'s own per-turn "volatile" block already
  changes every iteration and is deliberately kept outside every provider's
  cache_control region -- but ReactLoop's `cached_context/1` reuses the exact
  system-message BYTES across iterations to keep a provider's cache_control
  breakpoint stable, so anything appended there instead would either go stale
  (frozen at iteration 0) or, worse, land as the literal last message before
  `Providers.PromptCache.restructure/3` places its rolling breakpoint --
  which marks the LAST message with `cache_control`. A note that changes
  every step would then be exactly what gets marked, invalidating the
  breakpoint on every single turn instead of only at genuine content changes.

  So this note travels as `opts[:budget_note]` through the whole provider
  dispatch pipe (`Providers.Registry.chat/2`, `chat_stream/3`,
  `chat_with_fallback/3` all thread `opts` unchanged into
  `normalize_outbound_messages/3`) and is appended by
  `Providers.Registry.append_budget_note/2` as the ABSOLUTE LAST pipeline
  step -- after `Providers.PromptCache.restructure/3` has already placed its
  breakpoint on the true last history message. The note is therefore never
  cached, never marked, and never the thing a breakpoint is measured against.

  ## Tracking

  Per-turn state (started_at, cumulative output tokens) lives in a named ETS
  table keyed by session id -- the same pattern `Loop.GoalTracker` uses --
  because a session's ReAct loop iterations run recursively in one process,
  but the state must still survive a GenServer-mediated call boundary and be
  readable from tests without depending on process identity.

  Reset once per top-level turn, at iteration 0, by `ReactLoop.do_iteration/1`
  -- not once per LLM call, so a multi-iteration turn's countdown decreases
  monotonically instead of jumping back to full every step.
  """

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Settings

  @table :osa_turn_budget

  # Target output-token budget for a WHOLE turn (all iterations combined),
  # keyed by effort level -- task size scales the pacing target the same way
  # it already scales `Effort.max_iterations/0`. This is advisory: nothing
  # enforces it, it only shapes the note's "remaining" figure.
  @default_token_budgets %{
    fast: 60_000,
    medium: 150_000,
    high: 300_000,
    xhigh: 600_000,
    ultra: 1_000_000
  }

  @default_warn_steps 10
  @default_warn_frac 0.15

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          # Lost the race with a concurrent creator -- the table now exists.
          ArgumentError -> @table
        end

      _ref ->
        @table
    end
  end

  @doc """
  Start (or restart) per-turn tracking for `session_id`.

  Called once per top-level turn (`state.iteration == 0`), never per
  iteration -- see the moduledoc.
  """
  @spec start_turn(String.t()) :: :ok
  def start_turn(session_id) when is_binary(session_id) and session_id != "" do
    :ets.insert(
      table(),
      {session_id, %{started_at_ms: System.monotonic_time(:millisecond), output_tokens: 0}}
    )

    :ok
  rescue
    _ -> :ok
  end

  def start_turn(_session_id), do: :ok

  @doc """
  Accumulate one LLM round-trip's output tokens into the running turn total.

  Tolerant of atom- or string-keyed usage maps (providers vary -- see
  `Accounting.normalize_usage/1`, the same tolerance).
  """
  @spec record(String.t(), map()) :: :ok
  def record(session_id, usage)
      when is_binary(session_id) and session_id != "" and is_map(usage) do
    tokens = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0

    case :ets.lookup(table(), session_id) do
      [{^session_id, snap}] ->
        :ets.insert(table(), {session_id, %{snap | output_tokens: snap.output_tokens + tokens}})

      [] ->
        :ets.insert(
          table(),
          {session_id,
           %{started_at_ms: System.monotonic_time(:millisecond), output_tokens: tokens}}
        )
    end

    :ok
  rescue
    _ -> :ok
  end

  def record(_session_id, _usage), do: :ok

  @doc "Current per-turn snapshot for `session_id`, or a fresh zero snapshot if untracked."
  @spec snapshot(String.t()) :: %{started_at_ms: integer(), output_tokens: non_neg_integer()}
  def snapshot(session_id) when is_binary(session_id) do
    case :ets.lookup(table(), session_id) do
      [{^session_id, snap}] -> snap
      [] -> %{started_at_ms: System.monotonic_time(:millisecond), output_tokens: 0}
    end
  rescue
    _ -> %{started_at_ms: System.monotonic_time(:millisecond), output_tokens: 0}
  end

  def snapshot(_session_id),
    do: %{started_at_ms: System.monotonic_time(:millisecond), output_tokens: 0}

  @doc "Drop tracked state for `session_id` (session teardown)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    :ets.delete(table(), session_id)
    :ok
  rescue
    _ -> :ok
  end

  def clear(_session_id), do: :ok

  # ── Configuration (settings cascade -> app config -> effort-scaled default) ──

  @doc "Whether the per-step pacing note is shown at all. Default true."
  @spec enabled?() :: boolean()
  def enabled? do
    case Settings.get(:budget_note_enabled) do
      nil -> Application.get_env(:optimal_system_agent, :budget_note_enabled, true)
      v -> v
    end
  end

  @doc "The output-token budget target for a whole turn."
  @spec token_budget() :: pos_integer()
  def token_budget do
    Settings.get(:budget_turn_tokens) ||
      Application.get_env(:optimal_system_agent, :budget_turn_tokens) ||
      default_token_budget(Effort.current())
  end

  @doc "The effort-scaled default turn-token budget, before any override."
  @spec default_token_budget(atom() | String.t()) :: pos_integer()
  def default_token_budget(level) do
    Map.get(@default_token_budgets, Effort.normalize(level), @default_token_budgets[:medium])
  end

  @doc "Steps-remaining threshold below which the note switches to wrap-up wording."
  @spec warn_steps() :: pos_integer()
  def warn_steps do
    Settings.get(:budget_warn_steps) ||
      Application.get_env(:optimal_system_agent, :budget_warn_steps, @default_warn_steps)
  end

  @doc "Fraction (0..1) of the token budget remaining below which the note warns."
  @spec warn_frac() :: float()
  def warn_frac do
    Settings.get(:budget_warn_frac) ||
      Application.get_env(:optimal_system_agent, :budget_warn_frac, @default_warn_frac)
  end

  # ── The note itself ─────────────────────────────────────────────────────

  @doc """
  Build the compact per-step pacing note for this iteration, or `nil` when
  disabled or the state is missing what it needs.

  `state` must carry `:session_id` and `:iteration`; `max_iter` is the
  caller's resolved iteration ceiling (`ReactLoop.max_iterations/1`), or
  `:infinity` for an unbounded run — in which case the step half of the note
  is omitted (there is nothing to count down) but the token/elapsed half
  still renders.
  """
  @spec note(map(), pos_integer() | :infinity) :: String.t() | nil
  def note(%{session_id: session_id, iteration: iteration}, max_iter)
      when is_binary(session_id) and is_integer(iteration) and
             ((is_integer(max_iter) and max_iter > 0) or max_iter == :infinity) do
    if enabled?() do
      build_note(session_id, iteration, max_iter)
    end
  end

  def note(_state, _max_iter), do: nil

  defp build_note(session_id, iteration, max_iter) do
    snap = snapshot(session_id)
    elapsed_ms = max(System.monotonic_time(:millisecond) - snap.started_at_ms, 0)
    budget = token_budget()
    used = snap.output_tokens
    tok_remaining = max(budget - used, 0)
    step = iteration + 1

    token_warn? = budget > 0 and tok_remaining / budget <= warn_frac()

    {steps_part, steps_warn?} = steps_part(step, iteration, max_iter)

    nearly_spent? = steps_warn? or token_warn?

    base =
      "[Budget: #{steps_part}tokens ~#{fmt_tokens(used)}/#{fmt_tokens(budget)} " <>
        "(#{fmt_tokens(tok_remaining)} left) | elapsed #{fmt_duration(elapsed_ms)}]"

    if nearly_spent? do
      String.trim_trailing(base, "]") <>
        " -- BUDGET NEARLY SPENT: wrap up now. Summarize state and next steps " <>
        "instead of starting new work.]"
    else
      base
    end
  end

  defp steps_part(_step, _iteration, :infinity), do: {"", false}

  defp steps_part(step, iteration, max_iter) when is_integer(max_iter) do
    steps_remaining = max(max_iter - iteration, 0)
    warn? = steps_remaining <= warn_steps()
    {"step #{step}/#{max_iter} (#{steps_remaining} left) | ", warn?}
  end

  defp fmt_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp fmt_tokens(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1000)}k"
  defp fmt_tokens(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt_duration(ms) when is_integer(ms) do
    total_s = div(ms, 1_000)
    m = div(total_s, 60)
    s = rem(total_s, 60)
    if m > 0, do: "#{m}m#{s}s", else: "#{s}s"
  end
end
