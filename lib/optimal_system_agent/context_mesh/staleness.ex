defmodule OptimalSystemAgent.ContextMesh.Staleness do
  @moduledoc """
  4-factor staleness scoring for ContextMesh Keepers.

  ## Score (0 – 100)

  Each factor contributes up to 25 points of staleness:

    Time decay    — 5 points per hour since creation, capped at 25.
                    A keeper that has been alive for 5+ hours is maximally
                    time-stale regardless of any other factor.

    Access decay  — 25 if never accessed; decreases toward 0 as `last_accessed_at`
                    approaches the current time. Maxes out again after 5 hours
                    without any retrieval call.

    Relevance     — Inverse of the keeper's stored `relevance_score` (0.0 – 1.0).
                    A keeper with relevance_score 0.0 contributes 25; one with
                    relevance_score 1.0 contributes 0.

    Confidence    — Derived from the access_patterns hit/miss ratio. A keeper
                    with no successful retrievals contributes 25; perfect
                    hit-rate contributes 0. The ratio is approximated from the
                    access_patterns map stored in keeper state.

  ## States

    :fresh   — score  0 – 24   (healthy, keep in hot tier)
    :warm    — score 25 – 49   (usable, monitor)
    :stale   — score 50 – 74   (degraded, consider eviction)
    :expired — score 75 – 100  (archive candidate)
  """

  @doc """
  Compute the staleness score for a given keeper state map.

  Accepts either a `%OptimalSystemAgent.ContextMesh.Keeper{}` struct or the
  stats map returned by `OptimalSystemAgent.ContextMesh.Keeper.stats/2`.

  Returns `{score, state_atom}` where `score` is an integer in `0..100` and
  `state_atom` is one of `:fresh | :warm | :stale | :expired`.
  """
  @spec compute_staleness(map()) :: {non_neg_integer(), staleness_state()}
  def compute_staleness(keeper_state) when is_map(keeper_state) do
    score =
      time_decay(keeper_state) +
        access_decay(keeper_state) +
        relevance_decay(keeper_state) +
        confidence_decay(keeper_state)

    clamped = min(score, 100)
    {clamped, classify(clamped)}
  end

  @doc "Return the state atom for a raw score."
  @spec classify(non_neg_integer()) :: staleness_state()
  def classify(score) when score < 25, do: :fresh
  def classify(score) when score < 50, do: :warm
  def classify(score) when score < 75, do: :stale
  def classify(_score), do: :expired

  # ---------------------------------------------------------------------------
  # Factor: time decay (0 – 25)
  # ---------------------------------------------------------------------------

  defp time_decay(state) do
    created_at = Map.get(state, :created_at)
    hours = hours_since(created_at)
    min(round(hours * 5), 25)
  end

  # ---------------------------------------------------------------------------
  # Factor: access decay (0 – 25)
  # ---------------------------------------------------------------------------

  defp access_decay(state) do
    last = Map.get(state, :last_accessed_at)

    if is_nil(last) do
      # Never accessed
      25
    else
      hours = hours_since(last)
      # 0 points at access time, linearly scaling to 25 after 5 hours idle
      min(round(hours * 5), 25)
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: relevance decay (0 – 25)
  # ---------------------------------------------------------------------------

  defp relevance_decay(state) do
    relevance = Map.get(state, :relevance_score, 1.0)
    score = (1.0 - max(0.0, min(1.0, relevance))) * 25
    round(score)
  end

  # ---------------------------------------------------------------------------
  # Factor: confidence decay (0 – 25)
  # ---------------------------------------------------------------------------

  # Confidence is approximated from the access_patterns map.
  # Each entry is {{agent, mode}, count}. We treat :smart retrievals that
  # reached the LLM as "hits" and :keyword fallbacks as neutral; keepers with
  # no smart retrievals at all get max confidence decay (they have never been
  # proven useful via LLM synthesis).
  defp confidence_decay(state) do
    patterns = Map.get(state, :access_patterns, %{})

    total_retrievals =
      patterns
      |> Map.values()
      |> Enum.sum()

    smart_retrievals =
      patterns
      |> Enum.filter(fn {{_agent, mode}, _count} -> mode == :smart end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    cond do
      total_retrievals == 0 ->
        # Never retrieved — penalise fully
        25

      smart_retrievals == 0 ->
        # Retrieved but never via :smart — moderate penalty
        15

      true ->
        # Smart hit ratio: higher ratio → lower score
        ratio = smart_retrievals / total_retrievals
        round((1.0 - ratio) * 25)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp hours_since(nil), do: 5.0

  defp hours_since(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)
    max(0, seconds) / 3_600
  end

  defp hours_since(_), do: 5.0

  @type staleness_state :: :fresh | :warm | :stale | :expired
end
