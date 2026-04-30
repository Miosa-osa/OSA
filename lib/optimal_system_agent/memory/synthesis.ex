defmodule OptimalSystemAgent.Memory.Synthesis do
  @moduledoc """
  Memory synthesis — injection and compaction. Pure functions, no state.

  Coordinates two concerns:

    1. **Injection** — surface relevant memories into a message list before
       an LLM call. Queries Memory.Store, scores candidates, and prepends a
       formatted system message.

    2. **Compaction** — reduce context size when approaching token limits.
       Three tiers (warn / compact / emergency) with progressively heavier
       pruning strategies.

  ## Config keys (config.exs)

      compaction_warn:      0.80   # :warn threshold
      compaction_aggressive: 0.85  # :compact threshold
      compaction_emergency: 0.95   # :emergency threshold
  """

  require Logger

  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Memory.Scoring

  @default_inject_limit 5

  # ---------------------------------------------------------------------------
  # Injection
  # ---------------------------------------------------------------------------

  @doc """
  Inject relevant memories into a message list.

  Extracts keywords from the last user message in `messages`, queries
  Memory.Store for candidates, scores them, and prepends the top results
  as a single system message immediately after any existing system prompt.

  Also injects the Cortex bulletin if one is available.

  ## Options
    - `:limit` — max memories to inject (default: #{@default_inject_limit})

  Returns the enriched message list.
  """
  @spec inject([map()], String.t() | nil, keyword()) :: [map()]
  def inject(messages, session_id, opts \\ []) when is_list(messages) do
    limit = Keyword.get(opts, :limit, @default_inject_limit)

    query_text = last_user_content(messages)

    if query_text == "" do
      messages
    else
      query_keywords = Scoring.extract_keywords(query_text)

      relevant = fetch_and_score(query_text, query_keywords, session_id, limit)

      memory_block = format_memory_block(relevant)
      bulletin = fetch_bulletin()

      inject_blocks(messages, memory_block, bulletin)
    end
  end

  @doc """
  Compact a message list when it approaches the token limit.

  Checks the ratio `current_tokens / max_tokens` against three thresholds
  read from application config. Returns one of:

    - `{:ok, messages}`                       — under warn threshold, no action
    - `{:compacted, messages, removed_count}` — compaction applied

  ## Tiers

    - `:warn`      — trim old tool results (keep last 3 tool iterations)
    - `:compact`   — replace middle messages with a summary placeholder,
                     keep system prompt + last 5 messages verbatim
    - `:emergency` — keep ONLY system prompt + last 3 messages
  """
  @spec compact([map()], non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:compacted, [map()], non_neg_integer()}
  def compact(messages, current_tokens, max_tokens)
      when is_list(messages) and is_integer(current_tokens) and is_integer(max_tokens) do
    case check_threshold(current_tokens, max_tokens) do
      :ok ->
        {:ok, messages}

      :warn ->
        apply_warn_compaction(messages)

      :compact ->
        apply_compact_compaction(messages)

      :emergency ->
        apply_emergency_compaction(messages)
    end
  end

  @doc """
  Classify the current token usage against configured thresholds.

  Returns `:ok`, `:warn`, `:compact`, or `:emergency`.
  """
  @spec check_threshold(non_neg_integer(), pos_integer()) ::
          :ok | :warn | :compact | :emergency
  def check_threshold(current_tokens, max_tokens) when max_tokens > 0 do
    ratio = current_tokens / max_tokens

    emergency = Application.get_env(:optimal_system_agent, :compaction_emergency, 0.95)
    aggressive = Application.get_env(:optimal_system_agent, :compaction_aggressive, 0.85)
    warn = Application.get_env(:optimal_system_agent, :compaction_warn, 0.80)

    cond do
      ratio >= emergency -> :emergency
      ratio >= aggressive -> :compact
      ratio >= warn -> :warn
      true -> :ok
    end
  end

  def check_threshold(_current_tokens, _max_tokens), do: :ok

  # ---------------------------------------------------------------------------
  # Private — injection helpers
  # ---------------------------------------------------------------------------

  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn msg ->
      role = msg[:role] || msg["role"]
      to_string(role) == "user"
    end)
    |> case do
      nil -> ""
      msg -> to_string(msg[:content] || msg["content"] || "")
    end
  end

  defp fetch_and_score(query_text, query_keywords, session_id, limit) do
    case Memory.recall(query_text, limit: limit * 3) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          s = Scoring.score(entry, query_keywords, session_id)
          {s, entry}
        end)
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 1))

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("[Memory.Synthesis] fetch_and_score error: #{Exception.message(e)}")
      []
  end

  defp format_memory_block([]), do: nil

  defp format_memory_block(entries) do
    lines =
      Enum.map(entries, fn entry ->
        category = entry[:category] || entry["category"] || "context"
        content = entry[:content] || entry["content"] || ""
        "[memory:#{category}] #{content}"
      end)

    content = Enum.join(lines, "\n")

    %{role: "system", content: content}
  end

  defp fetch_bulletin do
    # Cortex bulletin not available in this build — return nil.
    nil
  end

  # Insert memory and bulletin blocks right after any leading system messages,
  # before the first non-system message (i.e. before conversation proper).
  defp inject_blocks(messages, nil, nil), do: messages

  defp inject_blocks(messages, memory_block, bulletin) do
    {system_prefix, rest} =
      Enum.split_while(messages, fn msg ->
        to_string(msg[:role] || msg["role"]) == "system"
      end)

    injected =
      [memory_block, bulletin]
      |> Enum.reject(&is_nil/1)

    system_prefix ++ injected ++ rest
  end

  # ---------------------------------------------------------------------------
  # Private — compaction helpers
  # ---------------------------------------------------------------------------

  # :warn — trim tool result messages outside the last 3 tool iterations
  defp apply_warn_compaction(messages) do
    {system_msgs, non_system} = split_system(messages)

    # Identify tool result messages (role: "tool")
    tool_result_indices =
      non_system
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _i} ->
        to_string(msg[:role] || msg["role"]) == "tool"
      end)
      |> Enum.map(&elem(&1, 1))

    # Keep the last 3 tool result messages, drop older ones
    indices_to_drop =
      tool_result_indices
      |> Enum.drop(-3)
      |> MapSet.new()

    before_count = length(non_system)

    trimmed =
      non_system
      |> Enum.with_index()
      |> Enum.reject(fn {_msg, i} -> MapSet.member?(indices_to_drop, i) end)
      |> Enum.map(&elem(&1, 0))

    removed = before_count - length(trimmed)
    result = system_msgs ++ trimmed

    if removed > 0 do
      Logger.info("[Memory.Synthesis] :warn compaction removed #{removed} old tool results")
      {:compacted, result, removed}
    else
      {:ok, messages}
    end
  end

  # :compact — summarize middle messages, keep system + last 5
  defp apply_compact_compaction(messages) do
    {system_msgs, non_system} = split_system(messages)

    keep_tail = 5
    total = length(non_system)

    if total <= keep_tail do
      {:ok, messages}
    else
      tail = Enum.take(non_system, -keep_tail)
      middle = Enum.take(non_system, total - keep_tail)

      summary_msg = %{
        role: "system",
        content: "[compacted: #{length(middle)} messages]"
      }

      result = system_msgs ++ [summary_msg] ++ tail

      Logger.info("[Memory.Synthesis] :compact removed #{length(middle)} middle messages")
      {:compacted, result, length(middle)}
    end
  end

  # :emergency — keep ONLY system prompt + last 3 messages
  defp apply_emergency_compaction(messages) do
    {system_msgs, non_system} = split_system(messages)

    keep_tail = 3
    total = length(non_system)

    if total <= keep_tail do
      {:ok, messages}
    else
      tail = Enum.take(non_system, -keep_tail)
      removed = total - keep_tail

      result = system_msgs ++ tail

      Logger.warning("[Memory.Synthesis] :emergency compaction removed #{removed} messages")
      {:compacted, result, removed}
    end
  end

  defp split_system(messages) do
    Enum.split_while(messages, fn msg ->
      to_string(msg[:role] || msg["role"]) == "system"
    end)
  end
end
