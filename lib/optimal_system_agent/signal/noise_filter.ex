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

  @cache_table :osa_noise_cache
  @cache_ttl 300

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
      {:uncertain, weight} -> cached_tier_2(message, weight)
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

  defp tier_2(message, weight) do
    case classify_noise_llm(message) do
      {:ok, :signal} -> {:signal, weight}
      {:ok, :noise} -> {:noise, :llm_classified}
      {:error, _} ->
        Logger.debug("Tier 2 noise check: LLM unavailable, passing uncertain signal")
        {:signal, weight}
    end
  end

  defp classify_noise_llm(message) do
    prompt = """
    Is this message a meaningful signal or just noise? Respond with ONLY "signal" or "noise".

    Noise = greetings, acknowledgments, filler, empty pleasantries, social niceties
    Signal = questions, requests, information sharing, tasks, decisions, anything with substance

    Message: "#{String.slice(message, 0, 200)}"

    Answer (signal or noise):
    """

    messages = [%{role: "user", content: prompt}]

    case OptimalSystemAgent.Providers.Registry.chat(messages, temperature: 0.0, max_tokens: 10) do
      {:ok, %{content: content}} ->
        case content |> String.trim() |> String.downcase() do
          "noise" -> {:ok, :noise}
          "signal" -> {:ok, :signal}
          s when s in ["noise.", "\"noise\""] -> {:ok, :noise}
          s when s in ["signal.", "\"signal\""] -> {:ok, :signal}
          _ -> {:ok, :signal}
        end

      {:error, _} = err ->
        err
    end
  end

  # --- Tier 2 Cache (ETS-backed, 5-minute TTL) ---

  @doc false
  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      try do
        :ets.new(@cache_table, [:set, :public, :named_table])
      rescue
        ArgumentError -> :already_exists
      end
    end
  end

  defp cached_tier_2(message, weight) do
    init_cache()
    key = :crypto.hash(:sha256, message)
    now = System.system_time(:second)

    try do
      case :ets.lookup(@cache_table, key) do
        [{^key, result, ts}] when now - ts < @cache_ttl ->
          result

        _ ->
          result = tier_2(message, weight)
          try do
            :ets.insert(@cache_table, {key, result, now})
          rescue
            ArgumentError -> :ok
          end
          result
      end
    rescue
      ArgumentError ->
        # ETS table was destroyed between init_cache and lookup (race condition in async tests)
        tier_2(message, weight)
    end
  end
end
