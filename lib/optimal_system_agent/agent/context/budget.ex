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

  @doc """
  Token budget for the RECALL block group.

      recall_budget = clamp(max(window * frac, floor), 0, leftover)

  Capped to a fraction of the REAL effective window (never the full leftover
  slack), floored so a genuinely relevant memory still fits after essentials
  on a small (e.g. 8k) window, and never exceeding the physically available
  leftover space.
  """
  @spec recall_budget(pos_integer(), integer()) :: non_neg_integer()
  def recall_budget(_effective_window, leftover) when leftover <= 0, do: 0

  def recall_budget(effective_window, leftover) do
    frac_cap = round(effective_window * dynamic_recall_budget_frac())

    frac_cap
    |> max(dynamic_recall_budget_floor())
    |> min(leftover)
  end
end
