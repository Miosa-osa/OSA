defmodule OptimalSystemAgent.Security.TaskDifficultyAssessment do
  @moduledoc """
  Task Difficulty Assessment (TDA) — four-dimension scoring that drives
  exploration vs exploitation decisions during a pentest.

  Adapted from the PENTESTGPT V2 research paper (85% on XBOW benchmark).
  The paper identified that the difference between 42% and 85% success rate
  was driven by smart exploration/exploitation decisions, not just better tools.

  ## Four dimensions

  1. **Horizon estimation** — how many steps remain until the task is complete?
     Lower horizon = more likely to succeed = exploit (keep going).
     Higher horizon = less certain = explore (try different approach).

  2. **Evidence confidence** — how confident are we in the current finding?
     High confidence = exploit (dig deeper on this finding).
     Low confidence = explore (look for other findings).

  3. **Context load** — how much context window is consumed?
     High context load = risk of forgetting = prefer exploitation (finish current).
     Low context load = room to explore.

  4. **Historical success rate** — has this approach type worked before?
     High success rate = exploit (keep using what works).
     Low success rate = explore (try something different).

  ## Decision

  The TDA returns `:exploit` (keep digging on current finding) or `:explore`
  (move to a new target/approach), with a confidence score and reasoning.

  ## Usage

      {:ok, assessment} = TaskDifficultyAssessment.assess(%{
        steps_remaining: 5,
        evidence_confidence: 0.8,
        context_load: 0.3,
        historical_success_rate: 0.6,
        task_type: :exploitation
      })

      # => %{decision: :exploit, confidence: 0.72, reasoning: "..."}
  """

  @type dimension :: :horizon | :confidence | :context_load | :success_rate
  @type decision :: :exploit | :explore
  @type assessment :: %{
          decision: decision(),
          confidence: float(),
          reasoning: String.t(),
          scores: map()
        }

  @type task_type :: :reconnaissance | :exploitation | :post_exploitation | :reporting

  @doc "Assess task difficulty and return an exploration vs exploitation decision."
  @spec assess(map()) :: {:ok, assessment()} | {:error, String.t()}
  def assess(opts) when is_map(opts) do
    horizon = Map.get(opts, :steps_remaining, 10)
    evidence_confidence = Map.get(opts, :evidence_confidence, 0.5)
    context_load = Map.get(opts, :context_load, 0.5)
    success_rate = Map.get(opts, :historical_success_rate, 0.5)
    task_type = Map.get(opts, :task_type, :exploitation)

    scores = %{
      horizon: score_horizon(horizon),
      confidence: score_confidence(evidence_confidence),
      context_load: score_context_load(context_load),
      success_rate: score_success_rate(success_rate)
    }

    # Weighted decision: exploit score vs explore score
    # Higher scores favor exploitation (keep going on current path)
    exploit_score =
      scores.confidence * 0.35 +
        scores.success_rate * 0.25 +
        (1.0 - scores.horizon) * 0.20 +
        scores.context_load * 0.20

    decision = if exploit_score >= 0.5, do: :exploit, else: :explore

    reasoning = build_reasoning(decision, scores, task_type)

    {:ok,
     %{
       decision: decision,
       confidence: Float.round(exploit_score, 2),
       reasoning: reasoning,
       scores: scores
     }}
  end

  def assess(_), do: {:error, "Invalid input: expected a map"}

  @doc "Score the horizon dimension (0-1). Lower steps remaining = higher score (favor exploit)."
  @spec score_horizon(non_neg_integer()) :: float()
  def score_horizon(steps_remaining) when is_integer(steps_remaining) and steps_remaining >= 0 do
    # Fewer steps remaining = more likely to succeed = higher score
    # 0 steps = 1.0 (certain), 20+ steps = 0.0 (very uncertain)
    max(0.0, min(1.0, 1.0 - steps_remaining / 20))
  end

  @doc "Score the evidence confidence dimension (0-1). Higher confidence = higher score."
  @spec score_confidence(float()) :: float()
  def score_confidence(confidence) when is_float(confidence) do
    max(0.0, min(1.0, confidence))
  end

  @doc "Score the context load dimension (0-1). Higher context load = higher exploit score (finish current work before context runs out)."
  @spec score_context_load(float()) :: float()
  def score_context_load(load) when is_float(load) do
    max(0.0, min(1.0, load))
  end

  @doc "Score the historical success rate (0-1). Higher success = higher exploit score."
  @spec score_success_rate(float()) :: float()
  def score_success_rate(rate) when is_float(rate) do
    max(0.0, min(1.0, rate))
  end

  @doc "Get a recommendation string for the agent."
  @spec recommendation(assessment()) :: String.t()
  def recommendation(%{decision: :exploit, reasoning: reasoning}), do: reasoning
  def recommendation(%{decision: :explore, reasoning: reasoning}), do: reasoning

  # ── Private ──────────────────────────────────────────────────────────────

  defp build_reasoning(:exploit, scores, task_type) do
    "Continue #{task_type} on current path. " <>
      build_score_breakdown(scores)
  end

  defp build_reasoning(:explore, scores, task_type) do
    "Switch to a different #{task_type} approach. " <>
      build_score_breakdown(scores)
  end

  defp build_score_breakdown(scores) do
    "Scores: confidence=#{Float.round(scores.confidence, 2)}, " <>
      "success_rate=#{Float.round(scores.success_rate, 2)}, " <>
      "horizon=#{Float.round(scores.horizon, 2)}, " <>
      "context_load=#{Float.round(scores.context_load, 2)}"
  end
end
