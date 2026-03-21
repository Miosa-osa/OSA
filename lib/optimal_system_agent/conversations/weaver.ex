defmodule OptimalSystemAgent.Conversations.Weaver do
  @moduledoc """
  Auto-summarizer for completed conversations.

  After a conversation ends, Weaver generates a structured summary by calling
  the default LLM provider with the full transcript. The summary is stored in
  the memory system for future recall and returned to the conversation initiator.

  ## Output structure

      %{
        key_decisions:     [String.t()],
        action_items:      [String.t()],
        dissenting_views:  [String.t()],
        open_questions:    [String.t()],
        summary:           String.t(),
        conversation_id:   String.t(),
        topic:             String.t(),
        participant_count: non_neg_integer(),
        turn_count:        non_neg_integer(),
        generated_at:      DateTime.t()
      }
  """

  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Memory

  @max_transcript_chars 12_000

  @doc """
  Generate and persist a structured summary for a completed conversation.

  `conversation_state` is the full GenServer state map from `Conversations.Server`.
  Returns `{:ok, summary_map}` or `{:error, reason}`.
  """
  @spec summarise(map()) :: {:ok, map()} | {:error, any()}
  def summarise(conversation_state) do
    transcript_text = format_transcript(conversation_state.transcript)

    prompt = build_prompt(conversation_state, transcript_text)

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 1500) do
      {:ok, %{content: raw}} ->
        parse_and_store(raw, conversation_state)

      {:ok, raw} when is_binary(raw) ->
        parse_and_store(raw, conversation_state)

      {:error, reason} ->
        Logger.warning("[Weaver] LLM summarisation failed: #{inspect(reason)}")
        {:error, {:llm_failed, reason}}
    end
  rescue
    e ->
      Logger.warning("[Weaver] summarise/1 exception: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Generate a summary synchronously from a conversation state map without
  storing to memory. Useful for testing or ephemeral use cases.
  """
  @spec summarise_dry(map()) :: {:ok, map()} | {:error, any()}
  def summarise_dry(conversation_state) do
    transcript_text = format_transcript(conversation_state.transcript)
    prompt = build_prompt(conversation_state, transcript_text)
    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 1500) do
      {:ok, %{content: raw}} -> parse_summary(raw, conversation_state)
      {:ok, raw} when is_binary(raw) -> parse_summary(raw, conversation_state)
      {:error, reason} -> {:error, {:llm_failed, reason}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_prompt(state, transcript_text) do
    participants =
      state.participants
      |> Enum.map_join(", ", fn p -> "#{p.name} (#{p.role})" end)

    """
    You are summarising a structured #{state.type} conversation.

    Topic: #{state.topic}
    Participants: #{participants}
    Turns taken: #{state.turn_count}

    Transcript:
    #{transcript_text}

    Produce a structured summary as valid JSON with exactly these keys:

    {
      "key_decisions":    ["..."],
      "action_items":     ["..."],
      "dissenting_views": ["..."],
      "open_questions":   ["..."],
      "summary":          "2-3 sentence overall summary"
    }

    Rules:
    - key_decisions: conclusions or choices the group converged on
    - action_items: concrete next steps (who does what, if determinable)
    - dissenting_views: minority positions or unresolved objections
    - open_questions: questions raised but not answered
    - summary: neutral prose summary of the conversation arc
    - Use empty arrays [] when a category has no entries
    - Respond ONLY with the JSON object, no commentary
    """
  end

  defp format_transcript(transcript) do
    full =
      transcript
      |> Enum.map_join("\n\n", fn {agent, msg, _ts} ->
        "#{agent}:\n#{msg}"
      end)

    if String.length(full) > @max_transcript_chars do
      String.slice(full, 0, @max_transcript_chars) <> "\n\n[transcript truncated]"
    else
      full
    end
  end

  defp parse_and_store(raw, state) do
    case parse_summary(raw, state) do
      {:ok, summary} ->
        store_in_memory(summary, state)
        {:ok, summary}

      error ->
        error
    end
  end

  defp parse_summary(raw, state) do
    cleaned =
      raw
      |> String.trim()
      |> strip_code_fences()

    case Jason.decode(cleaned) do
      {:ok, parsed} ->
        summary = %{
          conversation_id: Map.get(state, :id, "unknown"),
          topic: state.topic,
          type: state.type,
          participant_count: length(state.participants),
          turn_count: state.turn_count,
          key_decisions: list_field(parsed, "key_decisions"),
          action_items: list_field(parsed, "action_items"),
          dissenting_views: list_field(parsed, "dissenting_views"),
          open_questions: list_field(parsed, "open_questions"),
          summary: to_string(parsed["summary"] || ""),
          generated_at: DateTime.utc_now()
        }

        {:ok, summary}

      {:error, reason} ->
        Logger.warning("[Weaver] Failed to parse JSON: #{inspect(reason)} — raw: #{raw}")
        # Return a degraded summary rather than failing completely
        {:ok,
         %{
           conversation_id: Map.get(state, :id, "unknown"),
           topic: state.topic,
           type: state.type,
           participant_count: length(state.participants),
           turn_count: state.turn_count,
           key_decisions: [],
           action_items: [],
           dissenting_views: [],
           open_questions: [],
           summary: String.slice(raw, 0, 500),
           generated_at: DateTime.utc_now()
         }}
    end
  end

  defp store_in_memory(summary, state) do
    content = format_memory_content(summary)

    opts = [
      category: "context",
      tags: ["conversation", to_string(state.type), "summary"],
      signal_weight: 0.7,
      source: "conversations"
    ]

    case Memory.save(content, opts) do
      {:ok, _} ->
        Logger.debug("[Weaver] Summary stored in memory for topic: #{state.topic}")

      {:error, :duplicate} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Weaver] Memory store failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[Weaver] store_in_memory error: #{Exception.message(e)}")
  end

  defp format_memory_content(summary) do
    decisions =
      if summary.key_decisions != [],
        do: "\nKey decisions: #{Enum.join(summary.key_decisions, "; ")}",
        else: ""

    actions =
      if summary.action_items != [],
        do: "\nAction items: #{Enum.join(summary.action_items, "; ")}",
        else: ""

    """
    Conversation summary (#{summary.type}): #{summary.topic}
    #{summary.summary}#{decisions}#{actions}
    """
    |> String.trim()
  end

  defp list_field(map, key) do
    case Map.get(map, key) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp strip_code_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim()
  end
end
