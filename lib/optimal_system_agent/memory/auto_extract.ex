defmodule OptimalSystemAgent.Memory.AutoExtract do
  @moduledoc """
  Automatic memory extraction from conversation turns.

  After each user turn, scans the message for extractable memories: user
  preferences, decisions made, important facts, and corrections. Uses pattern
  matching for fast extraction without an LLM call.

  ## Precision over recall

  A false positive here is expensive and permanent: junk memories are injected
  into every future turn's context, where they mislead the agent until a human
  notices and deletes them. A false negative costs nothing — the agent can
  always call `memory_save` explicitly.

  Three guards enforce that bias:

    1. `machine_generated?/1` rejects text that is not a human talking —
       subagent task briefs, injected system context, reviewer prompts. The
       turn pipeline runs for subagent sessions too, where the "user message"
       is a machine-authored prompt; without this gate those get stored as
       user preferences.
    2. The patterns require an explicit standing-preference phrasing. Bare
       `I am`, `I need`, `I want` and `actually` are deliberately excluded —
       they match ordinary task requests ("I need help with this") far more
       often than durable facts.
    3. Only the matching SENTENCE is stored, never the whole message, and it
       must fall within `#{12}..#{300}` characters to qualify.
  """
  require Logger

  alias OptimalSystemAgent.Memory

  # A durable fact stated by a human is short. Anything longer is a task
  # brief, a pasted document, or a system prompt.
  @max_input_chars 1_500
  @min_fact_chars 12
  @max_fact_chars 300

  # Markers of machine-authored text. Matched case-insensitively against the
  # message. Any hit rejects the whole message.
  @machine_markers [
    "you are an ",
    "you are a ",
    "your job is to",
    "[shared scratchpad]",
    "<system-reminder>",
    "<task-notification>",
    "## handoff",
    "you must not",
    "do not reveal",
    "system prompt"
  ]

  # Patterns that indicate saveable information. Each must express a STANDING
  # fact, not a one-off request.
  @preference_patterns ~r/\b(I prefer|I always|I never|always use|never use|don'?t use|my preference is|our convention|we always|we never)\b/i
  @decision_patterns ~r/\b(we decided|the decision is|I chose|let'?s go with|we'?ll use|agreed to|committed to)\b/i
  @correction_patterns ~r/\b(no,? that'?s wrong|I meant|correction:|that'?s incorrect|wrong approach|not like that)\b/i
  @fact_patterns ~r/\b(the (password|key|url|endpoint|port|database|schema|table|api) is|credentials are|located at|deployed to|runs on|configured as)\b/i
  @name_patterns ~r/\b(my name is|I'?m called|call me)\b/i

  @patterns [
    {:preference, @preference_patterns},
    {:decision, @decision_patterns},
    {:correction, @correction_patterns},
    {:fact, @fact_patterns},
    {:identity, @name_patterns}
  ]

  @doc """
  Extract memories from a user message. Returns a list of memory entries to
  save, each holding only the sentence that matched — never the full message.

  Returns `[]` for machine-generated or oversized input.
  """
  @spec extract(term()) :: [%{type: atom(), content: String.t()}]
  def extract(user_message) when is_binary(user_message) do
    trimmed = String.trim(user_message)

    if extractable?(trimmed) do
      sentences = split_sentences(trimmed)

      @patterns
      |> Enum.flat_map(fn {type, pattern} ->
        case first_match(sentences, pattern) do
          nil -> []
          sentence -> [%{type: type, content: sentence}]
        end
      end)
    else
      []
    end
  end

  def extract(_), do: []

  @doc """
  Process extracted memories — persist each one under its mapped category.

  Returns the number of entries successfully saved (which may be fewer than
  the number supplied if the store rejects some).
  """
  @spec save_extracted([%{type: atom(), content: String.t()}], String.t()) :: non_neg_integer()
  def save_extracted(extractions, session_id \\ "auto") do
    Enum.count(extractions, fn %{type: type, content: content} ->
      try do
        case Memory.save(content,
               category: category_for(type),
               source: :agent,
               session_id: session_id,
               tags: ["auto_extract", to_string(type)]
             ) do
          {:error, reason} ->
            Logger.debug("[AutoExtract] store rejected #{type}: #{inspect(reason)}")
            false

          _ ->
            true
        end
      rescue
        e ->
          Logger.debug("[AutoExtract] save failed for #{type}: #{Exception.message(e)}")
          false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @spec extractable?(String.t()) :: boolean()
  defp extractable?(""), do: false

  defp extractable?(message) do
    String.length(message) <= @max_input_chars and not machine_generated?(message)
  end

  @doc false
  # Public for testing: the turn pipeline persists subagent turns through the
  # same path as human turns, so this gate is the only thing standing between
  # a reviewer prompt and the user's permanent preference list.
  @spec machine_generated?(String.t()) :: boolean()
  def machine_generated?(message) do
    downcased = String.downcase(message)
    Enum.any?(@machine_markers, &String.contains?(downcased, &1))
  end

  @spec split_sentences(String.t()) :: [String.t()]
  defp split_sentences(message) do
    message
    |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec first_match([String.t()], Regex.t()) :: String.t() | nil
  defp first_match(sentences, pattern) do
    Enum.find(sentences, fn sentence ->
      Regex.match?(pattern, sentence) and well_sized?(sentence)
    end)
  end

  @spec well_sized?(String.t()) :: boolean()
  defp well_sized?(sentence) do
    length = String.length(sentence)
    length >= @min_fact_chars and length <= @max_fact_chars
  end

  defp category_for(:preference), do: :preference
  defp category_for(:decision), do: :decision
  defp category_for(:correction), do: :lesson
  defp category_for(:fact), do: :context
  defp category_for(:identity), do: :context
  defp category_for(_type), do: :context
end
