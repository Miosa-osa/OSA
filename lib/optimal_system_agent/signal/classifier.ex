defmodule OptimalSystemAgent.Signal.Classifier do
  @moduledoc """
  Signal Theory 5-tuple classifier: S = (M, G, T, F, W)

  Every incoming communication is classified into:
  - M (Mode): What operational mode (EXECUTE, ASSIST, ANALYZE, BUILD, MAINTAIN)
  - G (Genre): Communicative purpose (DIRECT, INFORM, COMMIT, DECIDE, EXPRESS)
  - T (Type): Domain-specific category (question, request, report, etc.)
  - F (Format): Container format (message, document, notification, etc.)
  - W (Weight): Informational value [0.0, 1.0] — Shannon information content

  Architecture:
  - PRIMARY: LLM classification — understands intent, context, nuance
  - FALLBACK: Deterministic pattern matching — used only when LLM is unavailable

  The LLM is the primary classifier because understanding intent requires
  intelligence. "Help me build a rocket" is BUILD mode, not ASSIST — only
  an LLM understands that. Keyword matching produces false classifications.

  The deterministic path exists for:
  - Test environments (classifier_llm_enabled: false)
  - Offline/disconnected mode
  - LLM provider failures

  Classification results are cached in ETS (SHA256 key, 10-minute TTL)
  so repeated messages don't hit the LLM every time.

  Reference: Luna, R. (2026). Signal Theory: The Architecture of Optimal
  Intent Encoding in Communication Systems. https://zenodo.org/records/18774174
  """

  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.PromptLoader

  defstruct [
    :mode,
    :genre,
    :type,
    :format,
    :weight,
    :raw,
    :channel,
    :timestamp,
    confidence: :high
  ]

  @type confidence :: :high | :low

  @type t :: %__MODULE__{
          mode: :execute | :assist | :analyze | :build | :maintain,
          genre: :direct | :inform | :commit | :decide | :express,
          type: String.t(),
          format: :message | :document | :notification | :command | :transcript,
          weight: float(),
          raw: String.t(),
          channel: atom(),
          timestamp: DateTime.t(),
          confidence: confidence()
        }

  @cache_table :osa_classifier_cache
  @cache_ttl 600

  @doc """
  Classify a raw message into a Signal 5-tuple.

  When LLM is enabled (production): LLM classifies with full understanding.
  When LLM is disabled (tests/offline): Deterministic pattern matching.
  """
  def classify(message, channel \\ :cli) do
    if llm_enabled?() do
      # LLM-primary: use intelligence to understand intent
      case cached_classify_llm(message, channel) do
        {:ok, signal} ->
          signal

        {:error, _} ->
          # Fallback to deterministic ONLY when LLM is unavailable
          Logger.warning(
            "[Classifier] LLM unavailable, falling back to deterministic classification"
          )

          classify_deterministic(message, channel)
      end
    else
      # Test / offline mode: deterministic classification
      classify_deterministic(message, channel)
    end
  end

  # ---------------------------------------------------------------------------
  # LLM Classification (Primary)
  # ---------------------------------------------------------------------------

  @classification_prompt_fallback """
  You are a Signal Theory classifier. Classify this message into exactly 4 fields.
  Respond ONLY with a JSON object. No explanation, no markdown, no wrapping.

  ## Signal Theory Dimensions

  **mode** — What operational action does this message require?
  - EXECUTE: The user wants something done NOW (run, send, deploy, delete, trigger, sync, import, export)
  - BUILD: The user wants something CREATED (create, generate, write, scaffold, design, develop, implement, make something new)
  - ANALYZE: The user wants INSIGHT (analyze, report, compare, metrics, trend, dashboard, kpi, review data)
  - MAINTAIN: The user wants something FIXED or UPDATED (fix, update, migrate, backup, restore, rollback, patch, upgrade, debug)
  - ASSIST: The user wants HELP or GUIDANCE (explain, how do I, what is, help me understand, teach, clarify)

  Important: Classify by the PRIMARY INTENT, not by individual words.
  "Help me build a rocket" = BUILD (they want to build something)
  "Can you run the tests?" = EXECUTE (they want tests run)
  "What caused the crash?" = ANALYZE (they want analysis)
  "I need to fix the login" = MAINTAIN (they want a fix)

  **genre** — What is the communicative purpose?
  - DIRECT: A command or instruction — the user is telling you to do something
  - INFORM: Sharing information — the user is giving you facts or status
  - COMMIT: Making a promise — "I will", "let me", "I'll handle it"
  - DECIDE: Making or requesting a decision — approve, reject, confirm, cancel, choose
  - EXPRESS: Emotional expression — gratitude, frustration, praise, complaint

  **type** — Domain category:
  - question: Asking for information (contains ?, or starts with who/what/when/where/why/how)
  - request: Asking for an action to be performed
  - issue: Reporting a problem (error, bug, broken, crash, fail)
  - scheduling: Time-related (remind, schedule, later, tomorrow, next week)
  - summary: Asking for condensed information (summarize, recap, brief, overview)
  - report: Providing status or results
  - general: None of the above

  **weight** — Informational density (0.0 to 1.0):
  - 0.0-0.2: Noise (greetings, filler, single words)
  - 0.3-0.5: Low information (simple acknowledgments, short responses)
  - 0.5-0.7: Medium (standard questions, simple requests)
  - 0.7-0.9: High (complex tasks, multi-part requests, technical content)
  - 0.9-1.0: Critical (urgent issues, emergencies, production problems)

  ## Message to classify

  Channel: %CHANNEL%
  Message: "%MESSAGE%"

  Respond with ONLY: {"mode":"...","genre":"...","type":"...","weight":0.0}
  """

  defp classification_prompt do
    PromptLoader.get(:classifier, @classification_prompt_fallback)
  end

  defp classify_llm(message, channel) do
    # Truncate to prevent prompt injection via extremely long messages
    safe_message =
      message
      |> String.slice(0, 1000)
      |> String.replace("\"", "'")
      |> String.replace("\n", " ")

    prompt =
      classification_prompt()
      |> String.replace("%MESSAGE%", safe_message)
      |> String.replace("%CHANNEL%", to_string(channel))

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.0, max_tokens: 80) do
      {:ok, %{content: content}} ->
        parse_llm_result(content, message, channel)

      {:error, _} = err ->
        err
    end
  rescue
    e ->
      Logger.warning("[Classifier] LLM classification error: #{Exception.message(e)}")
      {:error, :llm_exception}
  end

  defp parse_llm_result(content, message, channel) do
    json_str =
      content
      |> String.trim()
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(json_str) do
      {:ok, data} when is_map(data) ->
        mode = parse_mode(data["mode"])
        genre = parse_genre(data["genre"])
        type = parse_type(data["type"])
        weight = parse_weight(data["weight"])

        {:ok,
         %__MODULE__{
           mode: mode || :assist,
           genre: genre || :inform,
           type: type || "general",
           format: classify_format(message, channel),
           weight: weight || calculate_weight(message),
           raw: message,
           channel: channel,
           timestamp: DateTime.utc_now(),
           confidence: :high
         }}

      {:error, _} ->
        # Try to extract JSON from prose response
        case Regex.run(~r/\{[^}]+\}/, json_str) do
          [json_match] ->
            case Jason.decode(json_match) do
              {:ok, data} -> parse_llm_result_from_data(data, message, channel)
              _ -> {:error, :parse_failed}
            end

          _ ->
            {:error, :parse_failed}
        end
    end
  end

  defp parse_llm_result_from_data(data, message, channel) do
    {:ok,
     %__MODULE__{
       mode: parse_mode(data["mode"]) || :assist,
       genre: parse_genre(data["genre"]) || :inform,
       type: parse_type(data["type"]) || "general",
       format: classify_format(message, channel),
       weight: parse_weight(data["weight"]) || calculate_weight(message),
       raw: message,
       channel: channel,
       timestamp: DateTime.utc_now(),
       confidence: :high
     }}
  end

  # ---------------------------------------------------------------------------
  # LLM Cache (ETS-backed, 10-minute TTL)
  # ---------------------------------------------------------------------------

  defp cached_classify_llm(message, channel) do
    ensure_cache()
    key = :crypto.hash(:sha256, "#{channel}:#{message}")
    now = System.system_time(:second)

    case :ets.lookup(@cache_table, key) do
      [{^key, {:ok, cached_signal}, ts}] when now - ts < @cache_ttl ->
        # Return cached result with fresh timestamp
        {:ok, %{cached_signal | timestamp: DateTime.utc_now()}}

      _ ->
        result = classify_llm(message, channel)

        case result do
          {:ok, _} = ok ->
            :ets.insert(@cache_table, {key, ok, now})
            ok

          error ->
            error
        end
    end
  end

  defp ensure_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:set, :public, :named_table])
    end
  end

  # ---------------------------------------------------------------------------
  # LLM Response Parsers
  # ---------------------------------------------------------------------------

  defp parse_mode(str) when is_binary(str) do
    case String.downcase(String.trim(str)) do
      "execute" -> :execute
      "assist" -> :assist
      "analyze" -> :analyze
      "build" -> :build
      "maintain" -> :maintain
      _ -> nil
    end
  end

  defp parse_mode(_), do: nil

  defp parse_genre(str) when is_binary(str) do
    case String.downcase(String.trim(str)) do
      "direct" -> :direct
      "inform" -> :inform
      "commit" -> :commit
      "decide" -> :decide
      "express" -> :express
      _ -> nil
    end
  end

  defp parse_genre(_), do: nil

  defp parse_type(str) when is_binary(str) do
    valid = ~w(question request issue scheduling summary report general)
    cleaned = String.downcase(String.trim(str))
    if cleaned in valid, do: cleaned, else: nil
  end

  defp parse_type(_), do: nil

  defp parse_weight(val) when is_float(val), do: max(0.0, min(1.0, val))
  defp parse_weight(val) when is_integer(val), do: max(0.0, min(1.0, val * 1.0))
  defp parse_weight(_), do: nil

  # ---------------------------------------------------------------------------
  # Config Guard
  # ---------------------------------------------------------------------------

  defp llm_enabled? do
    Application.get_env(:optimal_system_agent, :classifier_llm_enabled, true)
  end

  # ---------------------------------------------------------------------------
  # Deterministic Classification (Fallback)
  # ---------------------------------------------------------------------------

  @doc false
  def classify_deterministic(message, channel) do
    %__MODULE__{
      mode: classify_mode(message),
      genre: classify_genre(message),
      type: classify_type(message),
      format: classify_format(message, channel),
      weight: calculate_weight(message),
      raw: message,
      channel: channel,
      timestamp: DateTime.utc_now(),
      confidence: :low
    }
  end

  # --- Mode Classification (Beer's VSM S1-S5) ---

  defp classify_mode(msg) do
    lower = String.downcase(msg)

    cond do
      matches_word?(lower, ~w(build create generate make scaffold design)) or
          matches_word_strict?(lower, "new") ->
        :build

      matches_word?(lower, ~w(run execute trigger sync send import export)) ->
        :execute

      matches_word?(lower, ~w(analyze report dashboard metrics trend compare kpi)) ->
        :analyze

      matches_word?(lower, ~w(update upgrade migrate fix health backup restore rollback version)) ->
        :maintain

      true ->
        :assist
    end
  end

  # --- Genre Classification (Speech Act Theory) ---

  @commit_phrases ["i will", "i'll", "let me", "i promise", "i commit"]
  @express_words ~w(thanks love hate great terrible wow)

  defp classify_genre(msg) do
    lower = String.downcase(msg)

    cond do
      matches_word?(lower, ~w(please run make create send)) or
        matches_word_strict?(lower, "do") or
          String.ends_with?(lower, "!") ->
        :direct

      matches_phrase?(lower, @commit_phrases) ->
        :commit

      matches_word?(lower, ~w(approve reject cancel confirm decide)) or
          matches_word_strict?(lower, "set") ->
        :decide

      matches_word?(lower, @express_words) ->
        :express

      true ->
        :inform
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

    urgency_bonus =
      if matches_word?(String.downcase(msg), ~w(urgent asap critical emergency immediately)) or
           matches_word_strict?(String.downcase(msg), "now"), do: 0.2, else: 0.0

    noise_penalty =
      if matches_word?(String.downcase(msg), ~w(hello thanks lol haha)) or
           matches_any_word_strict?(String.downcase(msg), ~w(hi ok hey sure)), do: -0.3, else: 0.0

    (base + length_bonus + question_bonus + urgency_bonus + noise_penalty)
    |> max(0.0)
    |> min(1.0)
  end

  # --- Helpers ---

  defp matches_word?(text, keywords) when is_list(keywords) do
    Enum.any?(keywords, fn kw ->
      Regex.match?(~r/\b#{Regex.escape(kw)}/, text)
    end)
  end

  defp matches_word_strict?(text, keyword) do
    Regex.match?(~r/\b#{Regex.escape(keyword)}\b/, text)
  end

  defp matches_any_word_strict?(text, keywords) when is_list(keywords) do
    Enum.any?(keywords, fn kw ->
      Regex.match?(~r/\b#{Regex.escape(kw)}\b/, text)
    end)
  end

  defp matches_phrase?(text, phrases) when is_list(phrases) do
    Enum.any?(phrases, fn phrase ->
      Regex.match?(~r/\b#{Regex.escape(phrase)}\b/, text)
    end)
  end
end
