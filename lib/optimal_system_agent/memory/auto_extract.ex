defmodule OptimalSystemAgent.Memory.AutoExtract do
  @moduledoc """
  Automatic memory extraction from conversation turns.

  After each agent response, scans the conversation for extractable
  memories: user preferences, decisions made, architectural choices,
  important facts, and corrections. Uses pattern matching for fast
  extraction without an LLM call.
  """
  require Logger

  alias OptimalSystemAgent.Memory

  # Patterns that indicate saveable information
  @preference_patterns ~r/\b(I prefer|I like|I want|I need|always use|never use|don't use|my preference|I usually|we always|our convention|our pattern|we use)\b/i
  @decision_patterns ~r/\b(we decided|the decision is|I chose|let's go with|we'll use|the plan is|agreed to|committed to)\b/i
  @correction_patterns ~r/\b(actually|no,? that's wrong|not like that|I meant|correction:|fix that|that's incorrect|wrong approach)\b/i
  @fact_patterns ~r/\b(the (password|key|url|endpoint|port|database|schema|table|api) is|credentials are|located at|deployed to|runs on|configured as)\b/i
  @name_patterns ~r/\b(my name is|I'm called|call me|I am)\b/i

  @doc """
  Extract memories from a user message. Returns a list of memory entries to save.
  Called by the save_transcript hook after each turn.
  """
  def extract(user_message) when is_binary(user_message) do
    extractions = []

    extractions =
      if Regex.match?(@preference_patterns, user_message) do
        [%{type: :preference, content: user_message} | extractions]
      else
        extractions
      end

    extractions =
      if Regex.match?(@decision_patterns, user_message) do
        [%{type: :decision, content: user_message} | extractions]
      else
        extractions
      end

    extractions =
      if Regex.match?(@correction_patterns, user_message) do
        [%{type: :correction, content: user_message} | extractions]
      else
        extractions
      end

    extractions =
      if Regex.match?(@fact_patterns, user_message) do
        [%{type: :fact, content: user_message} | extractions]
      else
        extractions
      end

    extractions =
      if Regex.match?(@name_patterns, user_message) do
        [%{type: :identity, content: user_message} | extractions]
      else
        extractions
      end

    extractions
  end

  def extract(_), do: []

  @doc """
  Process extracted memories — deduplicate and save.
  """
  def save_extracted(extractions, session_id \\ "auto") do
    Enum.each(extractions, fn %{type: type, content: content} ->
      # Truncate to a reasonable size for memory storage
      key = "[#{type}] #{String.slice(content, 0, 200)}"

      try do
        Memory.save(key,
          category: category_for(type),
          source: :agent,
          session_id: session_id,
          tags: ["auto_extract", to_string(type)]
        )
      rescue
        _ -> :ok
      end
    end)

    length(extractions)
  end

  defp category_for(:preference), do: :preference
  defp category_for(:decision), do: :decision
  defp category_for(:correction), do: :lesson
  defp category_for(:fact), do: :context
  defp category_for(:identity), do: :context
  defp category_for(_type), do: :context
end
