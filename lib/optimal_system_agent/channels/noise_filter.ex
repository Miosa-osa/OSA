defmodule OptimalSystemAgent.Channels.NoiseFilter do
  @moduledoc """
  Two-tier noise filter that intercepts low-signal messages before they reach the LLM.

  ## Tier 1 — Deterministic regex (<1ms)
  Matches single characters, filler words, emoji-only strings, and pure punctuation.
  These get an immediate lightweight acknowledgment without any LLM call.

  ## Tier 2 — Signal weight check
  If a signal weight is provided (0.0–1.0), the weight is compared against configurable
  thresholds (defaults shown):
    - 0.00–0.15 → definitely noise (single chars, pure emoji) — filter with ack
    - 0.15–0.35 → likely noise (confirmations, filler) — filter with ack
    - 0.35–0.65 → uncertain — ask for clarification (Tier 2 LLM classification)
    - 0.65–1.00 → signal — process normally

  Thresholds are configurable via application environment:

      config :optimal_system_agent,
        noise_filter_thresholds: %{
          definitely_noise: 0.15,
          likely_noise: 0.35,
          uncertain: 0.65
        }

  Filters an estimated 40–60% of low-value messages that would otherwise
  trigger full LLM invocations.
  """

  @tier1_patterns [
    # Single character (any)
    ~r/^.$/u,
    # Common single-char acknowledgments: k, y, n, K, Y, N
    ~r/^[kynKYN]$/,
    # Confirmations (case-insensitive, whole string)
    ~r/^(ok|okay|sure|yep|yeah|nope|got it|gotcha|alright|roger|copy that|ten four|affirmative|yes|no|nah|yup|aye|noted|i see|i know|understood)$/i,
    # Thank-yous and reactions (greetings removed — users expect a chat response)
    ~r/^(np|no problem|no worries|sounds good|makes sense|got it)$/i,
    # Filler / reaction words
    ~r/^(lol|lmao|lmfao|haha|hehe|heh|hmm|meh|wow|omg|wtf|smh|rofl|brb|afk|gg|irl|imo|imho|fwiw|tl;?dr)$/i,
    # Short words with trailing punctuation (ok!, yep., k!, etc.)
    ~r/^[kynKYN][!?.]*$/,
    ~r/^(ok|okay|sure|yep|yeah|yes|no)[!?.]*$/i,
    # Emoji-only (covers most emoji Unicode ranges)
    ~r/^[\x{1F000}-\x{1FFFF}\x{2600}-\x{27FF}\x{FE00}-\x{FE0F}\x{1F900}-\x{1F9FF}\x{231A}-\x{23FF}\x{25A0}-\x{25FF}\x{2700}-\x{27BF}\s]+$/u,
    # Ellipsis or trailing dots only
    ~r/^\.{2,}$/,
    # Single or repeated punctuation only
    ~r/^[!?,;:\-_~*^@#%&+=|<>\/\\`'"]{1,5}$/,
    # Just whitespace/newlines (after trim, should not happen but guard it)
    ~r/^\s+$/
  ]

  @doc """
  Check a message against the noise filter.

  Returns:
    - `:pass`                       — message is substantive, send to LLM
    - `{:filtered, ack}`            — message is noise, return ack directly
    - `{:clarify, prompt}`          — message has low signal, ask for clarification
  """
  @spec check(String.t(), float() | nil) ::
          :pass | {:filtered, String.t()} | {:clarify, String.t()}
  def check(message, signal_weight \\ nil) when is_binary(message) do
    trimmed = String.trim(message)
    thresholds = weight_thresholds()

    cond do
      # Empty after trim — should not reach here normally
      trimmed == "" ->
        {:filtered, ""}

      # Tier 1: fast deterministic regex match
      tier1_match?(trimmed) ->
        {:filtered, acknowledgment(trimmed)}

      # Tier 2: noise (single chars, pure emoji, confirmations, filler) — 0.0–likely_noise
      is_number(signal_weight) and signal_weight < thresholds.likely_noise ->
        {:filtered, acknowledgment(trimmed)}

      # Tier 2: uncertain — needs clarification — likely_noise–uncertain
      is_number(signal_weight) and signal_weight < thresholds.uncertain ->
        {:clarify, clarification_prompt(trimmed)}

      # Tier 2: signal (0.65+) or no weight provided — process normally
      true ->
        :pass
    end
  end

  @doc """
  Returns the current weight threshold configuration.

  Reads from application env on every call so thresholds can be changed at runtime
  without restarting the process.
  """
  @spec weight_thresholds() :: %{
          definitely_noise: float(),
          likely_noise: float(),
          uncertain: float()
        }
  def weight_thresholds do
    defaults = %{definitely_noise: 0.15, likely_noise: 0.35, uncertain: 0.65}

    Application.get_env(:optimal_system_agent, :noise_filter_thresholds, defaults)
    |> then(fn cfg ->
      %{
        definitely_noise: Map.get(cfg, :definitely_noise, defaults.definitely_noise),
        likely_noise: Map.get(cfg, :likely_noise, defaults.likely_noise),
        uncertain: Map.get(cfg, :uncertain, defaults.uncertain)
      }
    end)
  end

  @doc """
  Adjusts noise filter weight thresholds at runtime based on historical data.

  `stats` is a map with counts for each bucket (e.g. from Telemetry.Metrics):
    %{"0.0-0.2": N, "0.2-0.5": N, "0.5-0.8": N, "0.8-1.0": N}

  Returns new thresholds. Does not persist — caller must set via
  Application.put_env/3 if desired.
  """
  @spec calibrate_weights(map(), map()) :: %{
          definitely_noise: float(),
          likely_noise: float(),
          uncertain: float()
        }
  def calibrate_weights(stats, opts \\ %{}) do
    current = weight_thresholds()

    low_bucket = Map.get(stats, :"0.0-0.2", 0)
    mid_bucket = Map.get(stats, :"0.2-0.5", 0)

    total =
      low_bucket + mid_bucket + Map.get(stats, :"0.5-0.8", 0) + Map.get(stats, :"0.8-1.0", 0)

    if total < 50 do
      # Not enough data to calibrate — return current thresholds unchanged
      current
    else
      # If >70% of traffic is in the low bucket, noise threshold is already catching
      # enough — tighten it slightly to avoid over-filtering borderline messages.
      # If <30%, loosen it to catch more noise.
      low_ratio = low_bucket / total

      step = Map.get(opts, :step, 0.02)
      min_dn = Map.get(opts, :min_definitely_noise, 0.10)
      max_dn = Map.get(opts, :max_definitely_noise, 0.25)

      new_dn =
        cond do
          low_ratio > 0.70 -> min(current.definitely_noise + step, max_dn)
          low_ratio < 0.30 -> max(current.definitely_noise - step, min_dn)
          true -> current.definitely_noise
        end

      %{current | definitely_noise: Float.round(new_dn, 3)}
    end
  end

  @doc """
  Synchronous version of check/2 that also handles the response output inline.
  Returns `true` if the message was filtered (caller should skip LLM), `false` otherwise.

  The `reply_fn` receives the response string and is responsible for output.
  """
  @spec filter_and_reply(String.t(), float() | nil, (String.t() -> any())) :: boolean()
  def filter_and_reply(message, signal_weight, reply_fn) do
    case check(message, signal_weight) do
      :pass ->
        false

      {:filtered, ""} ->
        # Completely silent filter (empty input)
        true

      {:filtered, ack} ->
        reply_fn.(ack)
        true

      {:clarify, prompt} ->
        reply_fn.(prompt)
        true
    end
  end

  # --- Private ---

  defp tier1_match?(input) do
    Enum.any?(@tier1_patterns, &Regex.match?(&1, input))
  end

  # Returns a brief, natural acknowledgment for noise messages.
  # Varies based on what the message looks like so it doesn't feel robotic.
  defp acknowledgment(input) do
    cond do
      # Confirmations
      Regex.match?(
        ~r/^(ok|okay|sure|yep|yeah|alright|roger|copy|affirmative|got it|gotcha)$/i,
        input
      ) ->
        Enum.random(["Got it.", "Sure.", "Noted.", "OK."])

      # Negations
      Regex.match?(~r/^(nope|no|nah|negative)$/i, input) ->
        Enum.random(["Understood.", "OK, no problem.", "Got it."])

      # Laughter / reactions
      Regex.match?(~r/^(lol|lmao|lmfao|haha|hehe|rofl)$/i, input) ->
        Enum.random(["Ha.", ":)", "Heh."])

      # Hmm / thinking sounds
      Regex.match?(~r/^(hmm+|umm+|uhh+|err+)$/i, input) ->
        Enum.random(["Take your time.", "I'm here when you're ready.", "Ready when you are."])

      # Emoji only
      Regex.match?(~r/^[\x{1F000}-\x{1FFFF}\x{2600}-\x{27FF}\s]+$/u, input) ->
        Enum.random(["Got it.", ":)", "Noted."])

      # Single k/y/n
      Regex.match?(~r/^[kKyYnN]$/, input) ->
        Enum.random(["Got it.", "OK.", "Sure."])

      # Everything else
      true ->
        Enum.random(["Got it.", "OK.", "Noted.", "Sure."])
    end
  end

  # Returns a clarification prompt for borderline low-signal messages.
  defp clarification_prompt(input) do
    "I want to make sure I help you correctly — could you share a bit more about \"#{input}\"? " <>
      "What would you like me to do?"
  end
end
