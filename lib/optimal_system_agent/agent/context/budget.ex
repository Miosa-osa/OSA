defmodule OptimalSystemAgent.Agent.Context.Budget do
  @moduledoc """
  Bounded budgets for memory recall and the dynamic-context RECALL block group.

  Mirrors Grok's MemorySearchConfig: recall is capped (max results), scored,
  and threshold-gated (min score) — never an unfiltered dump — and the RECALL
  block group in `Agent.Context` is capped to a fraction of the REAL effective
  context window instead of expanding into whatever slack is left over.

  All values are configurable via application env (see `config/config.exs`)
  and read at call time, so they can be overridden at runtime.
  """

  @doc "Maximum memory entries injected into the context (default: 6)."
  @spec memory_recall_max_results() :: pos_integer()
  def memory_recall_max_results,
    do: Application.get_env(:optimal_system_agent, :memory_recall_max_results, 6)

  @doc "Minimum relevance score for an entry to be injected (default: 0.35)."
  @spec memory_recall_min_score() :: float()
  def memory_recall_min_score,
    do: Application.get_env(:optimal_system_agent, :memory_recall_min_score, 0.35)

  @doc "Hard token cap for the rendered Long-term Memory block (default: 1200)."
  @spec memory_context_token_cap() :: pos_integer()
  def memory_context_token_cap,
    do: Application.get_env(:optimal_system_agent, :memory_context_token_cap, 1_200)

  @doc "Char cap for injected project context files (default: 8000)."
  @spec project_context_char_cap() :: pos_integer()
  def project_context_char_cap,
    do: Application.get_env(:optimal_system_agent, :project_context_char_cap, 8_000)

  @doc "Fraction of the effective window the RECALL group may use (default: 0.20)."
  @spec dynamic_recall_budget_frac() :: float()
  def dynamic_recall_budget_frac,
    do: Application.get_env(:optimal_system_agent, :dynamic_recall_budget_frac, 0.20)

  @doc "Floor (tokens) for the recall budget on small windows (default: 512)."
  @spec dynamic_recall_budget_floor() :: pos_integer()
  def dynamic_recall_budget_floor,
    do: Application.get_env(:optimal_system_agent, :dynamic_recall_budget_floor, 512)

  @doc "Tokens reserved for the model's response, kept out of the input budget (default: 4000)."
  @spec response_reserve() :: pos_integer()
  def response_reserve,
    do: Application.get_env(:optimal_system_agent, :context_response_reserve, 4_000)

  @doc """
  Canonical 3-bucket context budget breakdown (STATIC / CONVERSATION / DYNAMIC
  plus a response reserve).

      dynamic = max(max_tokens - reserve - static - conversation, dynamic_floor)

  Splits the effective window so both `Agent.Context.token_budget/1` and the
  assembler share ONE accurate formula: STATIC (cached Soul base) and
  CONVERSATION (message history) are fixed costs, `response_reserve` is held back
  for the reply, and DYNAMIC is whatever remains for per-request blocks — floored
  at `:dynamic_floor` (default 1000) so assembly always has minimal room even
  under heavy static/conversation pressure. `utilization_pct` is capped at 100.

  Options: `:response_reserve`, `:dynamic_floor`.
  """
  @spec three_bucket_budget(pos_integer(), non_neg_integer(), non_neg_integer(), keyword()) ::
          map()
  def three_bucket_budget(max_tokens, static_tokens, conversation_tokens, opts \\ [])
      when is_integer(max_tokens) and max_tokens > 0 and is_integer(static_tokens) and
             is_integer(conversation_tokens) do
    reserve = Keyword.get(opts, :response_reserve, response_reserve())
    floor = Keyword.get(opts, :dynamic_floor, 1_000)

    dynamic = max(max_tokens - reserve - static_tokens - conversation_tokens, floor)
    used = static_tokens + conversation_tokens + reserve

    %{
      max_tokens: max_tokens,
      static_tokens: static_tokens,
      conversation_tokens: conversation_tokens,
      response_reserve: reserve,
      dynamic_budget: dynamic,
      headroom: max(max_tokens - used, 0),
      utilization_pct: Float.round(min(used / max_tokens, 1.0) * 100, 1)
    }
  end

  @doc """
  Token budget for the RECALL block group.

      recall_budget = clamp(max(window * frac, floor), 0, leftover)

  Capped to a fraction of the REAL effective window (never the full leftover
  slack), floored so a genuinely relevant memory still fits after essentials
  on a small (e.g. 8k) window, and never exceeding the physically available
  leftover space.
  """
  @spec recall_budget(integer(), integer()) :: non_neg_integer()
  def recall_budget(_effective_window, leftover) when leftover <= 0, do: 0

  def recall_budget(effective_window, _leftover)
      when not is_integer(effective_window) or effective_window <= 0,
      do: 0

  def recall_budget(effective_window, leftover) do
    frac_cap = round(effective_window * dynamic_recall_budget_frac())

    frac_cap
    |> max(dynamic_recall_budget_floor())
    |> min(leftover)
  end
end
