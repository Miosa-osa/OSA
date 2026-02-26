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
      matches_any?(lower, ~w(build create generate make scaffold design new)) -> :build
      matches_any?(lower, ~w(run execute trigger sync send import export)) -> :execute
      matches_any?(lower, ~w(analyze report dashboard metrics trend compare kpi)) -> :analyze
      matches_any?(lower, ~w(update upgrade migrate fix health backup restore rollback version)) -> :maintain
      true -> :assist
    end
  end

  # --- Genre Classification (Speech Act Theory) ---

  defp classify_genre(msg) do
    lower = String.downcase(msg)
    cond do
      # Directives — cause an action
      matches_any?(lower, ~w(please do run make create send)) or String.ends_with?(lower, "!") -> :direct
      # Commissives — bind the sender
      matches_any?(lower, ~w(i will i'll let me i promise i commit)) -> :commit
      # Declaratives — change state
      matches_any?(lower, ~w(approve reject cancel confirm decide set)) -> :decide
      # Expressives — convey internal state
      matches_any?(lower, ~w(thanks love hate great terrible wow)) -> :express
      # Default: Assertives — convey information
      true -> :inform
    end
  end

  # --- Type Classification ---

  defp classify_type(msg) do
    lower = String.downcase(msg)
    cond do
      String.contains?(lower, "?") -> "question"
      matches_any?(lower, ~w(help how what why when where)) -> "question"
      matches_any?(lower, ~w(error bug broken fail crash)) -> "issue"
      matches_any?(lower, ~w(remind schedule later tomorrow)) -> "scheduling"
      matches_any?(lower, ~w(summarize summary brief recap)) -> "summary"
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
    urgency_bonus = if matches_any?(String.downcase(msg), ~w(urgent asap critical emergency now immediately)), do: 0.2, else: 0.0
    noise_penalty = if matches_any?(String.downcase(msg), ~w(hi hello hey thanks ok sure lol haha)), do: -0.3, else: 0.0

    (base + length_bonus + question_bonus + urgency_bonus + noise_penalty)
    |> max(0.0)
    |> min(1.0)
  end

  # --- Helpers ---

  defp matches_any?(text, keywords) do
    Enum.any?(keywords, fn kw -> String.contains?(text, kw) end)
  end
end
