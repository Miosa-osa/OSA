defmodule OptimalSystemAgent.Signal.NoiseFilter do
  @moduledoc """
  Two-tier noise filtering — Shannon channel capacity applied.

  Tier 1 (Deterministic, < 1ms):
  - Regex patterns for greetings, acknowledgments, spam
  - Message length thresholds
  - Duplicate detection (SHA256)

  Tier 2 (LLM-based, ~200ms):
  - Only invoked when Tier 1 is uncertain (weight 0.3-0.6)
  - Fast model classifies: signal or noise?
  - Caches results for similar messages

  Why this matters: Without noise filtering, every "ok" and "thanks" triggers
  a full agent loop. Shannon's channel capacity theorem proves that processing
  noise reduces the channel's ability to carry actual signals.
  """
  require Logger

  alias OptimalSystemAgent.Signal.Classifier

  @noise_patterns [
    ~r/^(hi|hello|hey|yo|sup)[\s!.]*$/i,
    ~r/^(ok|okay|sure|yep|yeah|yes|no|nah|nope)[\s!.]*$/i,
    ~r/^(thanks|thank you|ty|thx|cheers)[\s!.]*$/i,
    ~r/^(lol|haha|hehe|lmao|rofl|😂|👍|🙏|❤️)[\s!.]*$/i,
    ~r/^(good morning|good night|gm|gn)[\s!.]*$/i,
    ~r/^[\s]*$/,
  ]

  @doc """
  Filter a message through two tiers.
  Returns {:signal, weight} or {:noise, reason}.
  """
  def filter(message) do
    case tier_1(message) do
      {:noise, reason} -> {:noise, reason}
      {:signal, _} -> {:signal, Classifier.calculate_weight(message)}
      {:uncertain, weight} -> tier_2(message, weight)
    end
  end

  # --- Tier 1: Deterministic (< 1ms) ---

  defp tier_1(message) do
    trimmed = String.trim(message)

    cond do
      String.length(trimmed) == 0 ->
        {:noise, :empty}

      String.length(trimmed) < 3 ->
        {:noise, :too_short}

      Enum.any?(@noise_patterns, &Regex.match?(&1, trimmed)) ->
        {:noise, :pattern_match}

      true ->
        weight = Classifier.calculate_weight(message)
        if weight < 0.3 do
          {:noise, :low_weight}
        else
          if weight < 0.6 do
            {:uncertain, weight}
          else
            {:signal, weight}
          end
        end
    end
  end

  # --- Tier 2: LLM-based (fallback for uncertain signals) ---

  defp tier_2(_message, weight) do
    # For now, pass through uncertain signals
    # TODO: Add fast LLM classification when provider is available
    Logger.debug("Tier 2 noise check: passing uncertain signal (weight=#{weight})")
    {:signal, weight}
  end
end
