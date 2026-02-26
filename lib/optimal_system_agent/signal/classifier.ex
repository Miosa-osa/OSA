defmodule OptimalSystemAgent.Signal.Classifier do
  @moduledoc """
  Signal Theory 5-tuple classifier: S = (M, G, T, F, W)

  Every incoming communication is classified into:
  - M (Mode): What operational mode (EXECUTE, ASSIST, ANALYZE, BUILD, MAINTAIN)
  - G (Genre): Communicative purpose (DIRECT, INFORM, COMMIT, DECIDE, EXPRESS)
  - T (Type): Domain-specific category (question, request, report, etc.)
  - F (Format): Container format (message, document, notification, etc.)
  - W (Weight): Informational value [0.0, 1.0] — Shannon information content

  This is what makes OSA architecturally distinct from every other agent framework.
  OpenClaw, AutoGen, CrewAI — none classify signals before processing.

  Reference: Luna, R. (2026). Signal Theory: The Architecture of Optimal
  Intent Encoding in Communication Systems. https://zenodo.org/records/18774174
  """

  defstruct [:mode, :genre, :type, :format, :weight, :raw, :channel, :timestamp]

  @type t :: %__MODULE__{
    mode: :execute | :assist | :analyze | :build | :maintain,
    genre: :direct | :inform | :commit | :decide | :express,
    type: String.t(),
    format: :message | :document | :notification | :command | :transcript,
    weight: float(),
    raw: String.t(),
    channel: atom(),
    timestamp: DateTime.t()
  }

  @doc """
  Classify a raw message into a Signal 5-tuple.
  Uses deterministic pattern matching first (< 1ms), falls back to LLM only if needed.
  """
  def classify(message, channel \\ :cli) do
    %__MODULE__{
      mode: classify_mode(message),
      genre: classify_genre(message),
      type: classify_type(message),
      format: classify_format(message, channel),
      weight: calculate_weight(message),
      raw: message,
      channel: channel,
      timestamp: DateTime.utc_now()
    }
  end

  # --- Mode Classification (Beer's VSM S1-S5) ---

  defp classify_mode(msg) do
    lower = String.downcase(msg)
    cond do
      matches_word?(lower, ~w(build create generate make scaffold design)) or
        matches_word_strict?(lower, "new") -> :build
      matches_word?(lower, ~w(run execute trigger sync send import export)) -> :execute
      matches_word?(lower, ~w(analyze report dashboard metrics trend compare kpi)) -> :analyze
      matches_word?(lower, ~w(update upgrade migrate fix health backup restore rollback version)) -> :maintain
      true -> :assist
    end
  end

  # --- Genre Classification (Speech Act Theory) ---

  @commit_phrases ["i will", "i'll", "let me", "i promise", "i commit"]
  @express_words ~w(thanks love hate great terrible wow)

  defp classify_genre(msg) do
    lower = String.downcase(msg)
    cond do
      # Directives — cause an action
      matches_word?(lower, ~w(please run make create send)) or
        matches_word_strict?(lower, "do") or
        String.ends_with?(lower, "!") -> :direct
      # Commissives — bind the sender (multi-word phrases, not individual tokens)
      matches_phrase?(lower, @commit_phrases) -> :commit
      # Declaratives — change state
      matches_word?(lower, ~w(approve reject cancel confirm decide)) or
        matches_word_strict?(lower, "set") -> :decide
      # Expressives — convey internal state
      matches_word?(lower, @express_words) -> :express
      # Default: Assertives — convey information
      true -> :inform
    end
  end

  # --- Type Classification ---

  defp classify_type(msg) do
    lower = String.downcase(msg)
    cond do
      String.contains?(lower, "?") -> "question"
      matches_word?(lower, ~w(help how what why when where)) -> "question"
      matches_word?(lower, ~w(error bug broken fail crash)) -> "issue"
      matches_word?(lower, ~w(remind schedule later tomorrow)) -> "scheduling"
      matches_word?(lower, ~w(summarize summary brief recap)) -> "summary"
      true -> "general"
    end
  end

  # --- Format Classification ---

  defp classify_format(_msg, channel) do
    case channel do
      :cli -> :command
      :telegram -> :message
      :discord -> :message
      :slack -> :message
      :whatsapp -> :message
      :webhook -> :notification
      :filesystem -> :document
      _ -> :message
    end
  end

  # --- Weight Calculation (Shannon Information Content) ---

  @doc """
  Calculate the informational weight of a signal.
  Higher weight = more information content = higher priority.

  Factors:
  - Message length (longer = potentially more info, with diminishing returns)
  - Question marks (questions are inherently high-info requests)
  - Urgency markers
  - Uniqueness (not a greeting or small talk)
  """
  def calculate_weight(msg) do
    base = 0.5
    length_bonus = min(String.length(msg) / 500.0, 0.2)
    question_bonus = if String.contains?(msg, "?"), do: 0.15, else: 0.0
    urgency_bonus = if matches_word?(String.downcase(msg), ~w(urgent asap critical emergency immediately)) or
                       matches_word_strict?(String.downcase(msg), "now"), do: 0.2, else: 0.0
    noise_penalty = if matches_word?(String.downcase(msg), ~w(hello thanks lol haha)) or
                       matches_any_word_strict?(String.downcase(msg), ~w(hi ok hey sure)), do: -0.3, else: 0.0

    (base + length_bonus + question_bonus + urgency_bonus + noise_penalty)
    |> max(0.0)
    |> min(1.0)
  end

  # --- Helpers ---

  # Word-start boundary matching: "crash" matches "crash" and "crashing"
  # but not "acrash". Allows morphological variants (suffixed forms).
  defp matches_word?(text, keywords) when is_list(keywords) do
    Enum.any?(keywords, fn kw ->
      Regex.match?(~r/\b#{Regex.escape(kw)}/, text)
    end)
  end

  # Strict whole-word matching for short keywords prone to false positives
  # as prefixes of other words: "do" matches "do this" but NOT "document" or "done".
  defp matches_word_strict?(text, keyword) do
    Regex.match?(~r/\b#{Regex.escape(keyword)}\b/, text)
  end

  # Strict whole-word matching for a list of short keywords.
  defp matches_any_word_strict?(text, keywords) when is_list(keywords) do
    Enum.any?(keywords, fn kw ->
      Regex.match?(~r/\b#{Regex.escape(kw)}\b/, text)
    end)
  end

  # Phrase matching: checks if the text contains any of the given multi-word phrases.
  # Each phrase is matched as a contiguous substring with word boundaries.
  defp matches_phrase?(text, phrases) when is_list(phrases) do
    Enum.any?(phrases, fn phrase ->
      Regex.match?(~r/\b#{Regex.escape(phrase)}\b/, text)
    end)
  end
end
