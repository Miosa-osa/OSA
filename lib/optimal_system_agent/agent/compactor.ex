defmodule OptimalSystemAgent.Agent.Compactor do
  @moduledoc """
  Context compaction — 3-tier threshold system.

  Monitors context window usage and compresses when thresholds are hit.
  Called by the agent loop via `maybe_compact/1` BEFORE building context
  each iteration.

  Tiers (evaluated highest-priority first):
  - Tier 3 — Emergency Truncate (> 95% of max_tokens):
      No LLM call. Keep system messages + last 10 messages.
      Prepends a truncation notice derived from dropped user messages.

  - Tier 2 — Aggressive Compress (> 85% of max_tokens):
      LLM-summarizes the oldest 50% of non-system messages into a
      single short "key facts" summary, then replaces them.

  - Tier 1 — Background Summarize (> 80% of max_tokens):
      LLM-summarizes the oldest 30% of non-system messages into a
      concise summary, then replaces them.

  If an LLM summarization call fails, falls back to emergency truncation.
  `maybe_compact/1` is wrapped in try/rescue and will NEVER crash; on any
  unexpected error it returns the original message list unchanged.

  The GenServer tracks compaction metrics accessible via `stats/0`.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @max_tokens Application.compile_env(:optimal_system_agent, :max_context_tokens, 128_000)

  @tier1_threshold 0.80
  @tier2_threshold 0.85
  @tier3_threshold 0.95

  # ---------------------------------------------------------------------------
  # GenServer state
  # ---------------------------------------------------------------------------

  defstruct compaction_count: 0,
            tokens_saved: 0,
            last_compacted_at: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Returns current compaction metrics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Inspects the given message list and compacts it if any usage threshold is
  exceeded. Returns the (possibly compacted) message list.

  This function is safe — it never raises. On any unexpected error it returns
  the original messages unchanged.
  """
  @spec maybe_compact([map()]) :: [map()]
  def maybe_compact(messages) do
    try do
      do_maybe_compact(messages)
    rescue
      e ->
        Logger.error("Compactor.maybe_compact/1 crashed unexpectedly: #{Exception.message(e)}")
        messages
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%__MODULE__{} = state) do
    Logger.info("Compactor started (max_tokens=#{@max_tokens})")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    metrics = %{
      compaction_count: state.compaction_count,
      tokens_saved: state.tokens_saved,
      last_compacted_at: state.last_compacted_at
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_cast({:record_compaction, tokens_saved}, state) do
    updated = %{
      state
      | compaction_count: state.compaction_count + 1,
        tokens_saved: state.tokens_saved + tokens_saved,
        last_compacted_at: DateTime.utc_now()
    }

    {:noreply, updated}
  end

  # ---------------------------------------------------------------------------
  # Core compaction logic (module-level, pure-ish functions)
  # ---------------------------------------------------------------------------

  defp do_maybe_compact(messages) do
    tokens_before = estimate_tokens(messages)
    usage_ratio = tokens_before / @max_tokens

    cond do
      usage_ratio > @tier3_threshold ->
        compacted = emergency_truncate(messages)
        tokens_after = estimate_tokens(compacted)
        record_compaction(tokens_before - tokens_after)

        Logger.warning(
          "Compactor Tier 3 (emergency truncate): #{tokens_before} → #{tokens_after} tokens " <>
            "(#{Float.round(usage_ratio * 100, 1)}% → #{Float.round(tokens_after / @max_tokens * 100, 1)}%)"
        )

        compacted

      usage_ratio > @tier2_threshold ->
        compacted = aggressive_compress(messages)
        tokens_after = estimate_tokens(compacted)
        record_compaction(tokens_before - tokens_after)

        Logger.info(
          "Compactor Tier 2 (aggressive compress): #{tokens_before} → #{tokens_after} tokens " <>
            "(#{Float.round(usage_ratio * 100, 1)}% → #{Float.round(tokens_after / @max_tokens * 100, 1)}%)"
        )

        compacted

      usage_ratio > @tier1_threshold ->
        compacted = background_summarize(messages)
        tokens_after = estimate_tokens(compacted)
        record_compaction(tokens_before - tokens_after)

        Logger.info(
          "Compactor Tier 1 (background summarize): #{tokens_before} → #{tokens_after} tokens " <>
            "(#{Float.round(usage_ratio * 100, 1)}% → #{Float.round(tokens_after / @max_tokens * 100, 1)}%)"
        )

        compacted

      true ->
        messages
    end
  end

  # ---------------------------------------------------------------------------
  # Tier implementations
  # ---------------------------------------------------------------------------

  # Tier 1: summarize oldest 30% of non-system messages
  defp background_summarize(messages) do
    {system_msgs, non_system} = split_system(messages)

    {to_summarize, to_keep} = split_oldest_pct(non_system, 0.30)

    prompt = """
    Summarize the following conversation excerpt concisely. Preserve key facts,
    decisions, and context that would be needed to continue the conversation.

    #{format_for_summary(to_summarize)}
    """

    case call_summary_llm(prompt) do
      {:ok, summary} ->
        summary_msg = %{role: "system", content: "[Context Summary]\n#{summary}"}
        system_msgs ++ [summary_msg] ++ to_keep

      {:error, reason} ->
        Logger.error("Compactor Tier 1 LLM summarization failed: #{inspect(reason)}. Falling back to emergency truncate.")
        emergency_truncate(messages)
    end
  end

  # Tier 2: summarize oldest 50% of non-system messages (shorter prompt)
  defp aggressive_compress(messages) do
    {system_msgs, non_system} = split_system(messages)

    {to_summarize, to_keep} = split_oldest_pct(non_system, 0.50)

    prompt = """
    Compress the following conversation into the shortest possible list of key facts.
    Be extremely terse — bullet points only, no prose.

    #{format_for_summary(to_summarize)}
    """

    case call_summary_llm(prompt) do
      {:ok, summary} ->
        summary_msg = %{role: "system", content: "[Context Summary]\n#{summary}"}
        system_msgs ++ [summary_msg] ++ to_keep

      {:error, reason} ->
        Logger.error("Compactor Tier 2 LLM summarization failed: #{inspect(reason)}. Falling back to emergency truncate.")
        emergency_truncate(messages)
    end
  end

  # Tier 3: no LLM call — keep system messages + last 10 non-system messages
  defp emergency_truncate(messages) do
    {system_msgs, non_system} = split_system(messages)

    keep_count = 10
    total = length(non_system)

    {dropped, kept} =
      if total > keep_count do
        Enum.split(non_system, total - keep_count)
      else
        {[], non_system}
      end

    topic_notice = %{
      role: "system",
      content:
        "[Context truncated due to length. Earlier conversation was about: #{extract_topics(dropped)}]"
    }

    system_msgs ++ [topic_notice] ++ kept
  end

  # ---------------------------------------------------------------------------
  # LLM helper
  # ---------------------------------------------------------------------------

  defp call_summary_llm(prompt) do
    messages = [%{role: "user", content: prompt}]

    Providers.chat(messages, temperature: 0.3, max_tokens: 512)
    |> case do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, %{content: content}} ->
        {:error, "Empty summary response: #{inspect(content)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp estimate_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content = Map.get(msg, :content) || ""
      acc + div(String.length(to_string(content)), 4)
    end)
  end

  defp split_system(messages) do
    Enum.split_with(messages, fn msg ->
      to_string(Map.get(msg, :role)) == "system"
    end)
  end

  # Returns {oldest_pct, newest_1-pct} preserving order within each part.
  defp split_oldest_pct(messages, pct) when pct > 0 and pct < 1 do
    total = length(messages)
    n_oldest = max(1, round(total * pct))
    Enum.split(messages, n_oldest)
  end

  defp split_oldest_pct(messages, _pct), do: {[], messages}

  defp format_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = to_string(Map.get(msg, :role, "unknown"))
      content = to_string(Map.get(msg, :content) || "")
      "#{role}: #{content}"
    end)
    |> Enum.join("\n")
  end

  @doc false
  defp extract_topics(messages) do
    messages
    |> Enum.filter(fn msg -> to_string(Map.get(msg, :role)) == "user" end)
    |> Enum.map(fn msg ->
      content = to_string(Map.get(msg, :content) || "")
      String.slice(content, 0, 100)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
    |> String.slice(0, 500)
  end

  defp record_compaction(tokens_saved) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:record_compaction, tokens_saved})
    end
  end
end
