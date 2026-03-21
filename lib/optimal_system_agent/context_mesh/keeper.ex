defmodule OptimalSystemAgent.ContextMesh.Keeper do
  @moduledoc """
  Per-team GenServer that stores conversation context as a message list.

  ## Architecture

  Each team gets one Keeper process, started on demand by
  `OptimalSystemAgent.ContextMesh.Supervisor`. The Keeper owns:

    - An in-memory message list with per-message token estimates
    - A dirty flag + debounced timer for 50 ms persistence flushes
    - Access pattern tracking (agent name, retrieval mode, count)

  ## Retrieval Modes

    :keyword — Split the query into words, score every message by overlap with
               those words, return the top-N messages that fit within a 10 K
               token budget.

    :smart   — Send the full context plus the query to the LLM and return its
               synthesised answer. Falls back to :keyword on any failure.

    :full    — Return all messages when the total context is ≤ 10 K tokens,
               otherwise fall through to :keyword.

  ## Auto-summarisation

  When the accumulated token count exceeds 5 000 tokens the Keeper requests a
  summary from the LLM and prepends it as a synthetic `:system` message, then
  trims messages that are already covered by the summary.

  ## Persistence

  State is flushed through `OptimalSystemAgent.ContextMesh.Archiver` (or any
  injected flush callback). The flush is debounced at 50 ms so rapid bursts of
  `add_message` calls collapse into a single write.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @token_budget 10_000
  @summarise_threshold 5_000
  @debounce_ms 50

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  defstruct team_id: nil,
            keeper_id: nil,
            messages: [],
            token_count: 0,
            dirty: false,
            flush_timer: nil,
            access_patterns: %{},
            created_at: nil,
            last_accessed_at: nil,
            flush_fn: nil

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start a Keeper for `team_id`.

  Options:
    - `:keeper_id` — unique id within the team (defaults to `team_id`)
    - `:flush_fn`  — 1-arity function called with the keeper state on flush
                     (defaults to a no-op)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    keeper_id = Keyword.get(opts, :keeper_id, team_id)
    name = via(team_id, keeper_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a message map to the context. Triggers debounced persistence."
  @spec add_message(String.t(), String.t(), map()) :: :ok
  def add_message(team_id, keeper_id \\ nil, message) do
    GenServer.cast(via(team_id, keeper_id || team_id), {:add_message, message})
  end

  @doc """
  Retrieve context using the given mode.

  Returns `{:ok, result}` where result is a list of messages (`:keyword`,
  `:full`) or a binary string (`:smart`).
  """
  @spec retrieve(String.t(), String.t(), String.t(), retrieval_mode()) ::
          {:ok, [map()] | String.t()} | {:error, term()}
  def retrieve(team_id, keeper_id \\ nil, query, mode)

  def retrieve(team_id, keeper_id, query, mode) when is_nil(keeper_id) do
    retrieve(team_id, team_id, query, mode)
  end

  def retrieve(team_id, keeper_id, query, mode) do
    GenServer.call(via(team_id, keeper_id), {:retrieve, query, mode}, 15_000)
  end

  @doc "Return current stats for monitoring and staleness scoring."
  @spec stats(String.t(), String.t()) :: map()
  def stats(team_id, keeper_id \\ nil) do
    GenServer.call(via(team_id, keeper_id || team_id), :stats)
  end

  @doc "Force an immediate flush of any pending dirty state."
  @spec flush(String.t(), String.t()) :: :ok
  def flush(team_id, keeper_id \\ nil) do
    GenServer.call(via(team_id, keeper_id || team_id), :flush)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    keeper_id = Keyword.get(opts, :keeper_id, team_id)
    flush_fn = Keyword.get(opts, :flush_fn, fn _state -> :ok end)

    now = DateTime.utc_now()

    state = %__MODULE__{
      team_id: team_id,
      keeper_id: keeper_id,
      messages: [],
      token_count: 0,
      dirty: false,
      flush_timer: nil,
      access_patterns: %{},
      created_at: now,
      last_accessed_at: now,
      flush_fn: flush_fn
    }

    Logger.debug("[ContextMesh.Keeper] started team=#{team_id} id=#{keeper_id}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:add_message, message}, state) do
    tokens = estimate_tokens(message)

    new_messages = state.messages ++ [Map.put(message, :__tokens, tokens)]
    new_count = state.token_count + tokens

    state =
      %{state | messages: new_messages, token_count: new_count, dirty: true}
      |> maybe_auto_summarise()
      |> schedule_flush()

    {:noreply, state}
  end

  @impl true
  def handle_call({:retrieve, query, mode}, _from, state) do
    state = record_access(state, mode)
    result = do_retrieve(query, mode, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = build_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:debounce_flush, state) do
    state = %{do_flush(state) | flush_timer: nil}
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.dirty do
      Logger.debug(
        "[ContextMesh.Keeper] terminating (#{inspect(reason)}) — flushing pending state"
      )

      do_flush(state)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Retrieval
  # ---------------------------------------------------------------------------

  defp do_retrieve(_query, :full, state) do
    if state.token_count <= @token_budget do
      {:ok, clean_messages(state.messages)}
    else
      do_retrieve_keyword("", state)
    end
  end

  defp do_retrieve(query, :keyword, state) do
    do_retrieve_keyword(query, state)
  end

  defp do_retrieve(query, :smart, state) do
    case do_retrieve_smart(query, state) do
      {:ok, answer} ->
        {:ok, answer}

      {:error, reason} ->
        Logger.warning(
          "[ContextMesh.Keeper] smart retrieval failed (#{inspect(reason)}), falling back to :keyword"
        )

        do_retrieve_keyword(query, state)
    end
  end

  # :keyword — score messages by word overlap, collect top-N within budget
  defp do_retrieve_keyword(query, state) do
    query_words = tokenise_query(query)

    scored =
      state.messages
      |> Enum.map(fn msg ->
        score = keyword_score(msg, query_words)
        {score, msg}
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    {selected, _} =
      Enum.reduce(scored, {[], 0}, fn {_score, msg}, {acc, used} ->
        msg_tokens = Map.get(msg, :__tokens, 0)

        if used + msg_tokens <= @token_budget do
          {[msg | acc], used + msg_tokens}
        else
          {acc, used}
        end
      end)

    {:ok, selected |> Enum.reverse() |> clean_messages()}
  end

  # :smart — forward all context + query to LLM, return synthesised text
  defp do_retrieve_smart(query, state) do
    formatted = format_messages_for_llm(state.messages)

    system_prompt = """
    You are a context retrieval assistant. Given the conversation context below,
    answer the following query concisely. Focus only on information present in the
    context. If the context does not contain relevant information, say so briefly.
    """

    messages = [
      %{role: "system", content: system_prompt},
      %{
        role: "user",
        content: "Context:\n#{formatted}\n\nQuery: #{query}"
      }
    ]

    case Providers.chat(messages, temperature: 0.1, max_tokens: 512) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, resp} ->
        {:error, {:unexpected_response, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Auto-summarisation
  # ---------------------------------------------------------------------------

  defp maybe_auto_summarise(%{token_count: count} = state) when count > @summarise_threshold do
    case request_summary(state.messages) do
      {:ok, summary_text} ->
        summary_msg = %{
          role: "system",
          content: "[Context Summary]\n#{summary_text}",
          __tokens: estimate_tokens_text(summary_text),
          __summarised_at: DateTime.utc_now()
        }

        # Keep the last 10 messages verbatim, replace the rest with the summary
        hot_count = min(10, length(state.messages))
        hot = Enum.take(state.messages, -hot_count)

        new_messages = [summary_msg | hot]
        new_count = Enum.reduce(new_messages, 0, &(Map.get(&1, :__tokens, 0) + &2))

        Logger.info(
          "[ContextMesh.Keeper] team=#{state.team_id} auto-summarised: " <>
            "#{state.token_count} -> #{new_count} tokens"
        )

        %{state | messages: new_messages, token_count: new_count}

      {:error, reason} ->
        Logger.warning(
          "[ContextMesh.Keeper] auto-summarise failed: #{inspect(reason)}, keeping full context"
        )

        state
    end
  end

  defp maybe_auto_summarise(state), do: state

  defp request_summary(messages) do
    formatted = format_messages_for_llm(messages)

    prompt_messages = [
      %{
        role: "user",
        content:
          "Summarise the following conversation concisely. Preserve key facts, decisions, " <>
            "and outcomes needed to continue the conversation. Use bullet points.\n\n#{formatted}"
      }
    ]

    case Providers.chat(prompt_messages, temperature: 0.1, max_tokens: 512) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, resp} ->
        {:error, {:unexpected_response, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Persistence (debounced)
  # ---------------------------------------------------------------------------

  defp schedule_flush(%{dirty: false} = state), do: state

  defp schedule_flush(%{flush_timer: nil} = state) do
    ref = Process.send_after(self(), :debounce_flush, @debounce_ms)
    %{state | flush_timer: ref}
  end

  defp schedule_flush(state), do: state

  defp do_flush(%{dirty: false} = state), do: state

  defp do_flush(state) do
    try do
      state.flush_fn.(state)
    rescue
      e ->
        Logger.warning("[ContextMesh.Keeper] flush error: #{Exception.message(e)}")
    end

    %{state | dirty: false}
  end

  # ---------------------------------------------------------------------------
  # Access pattern tracking
  # ---------------------------------------------------------------------------

  defp record_access(state, mode) do
    agent = caller_agent()

    patterns =
      Map.update(state.access_patterns, {agent, mode}, 1, &(&1 + 1))

    %{state | access_patterns: patterns, last_accessed_at: DateTime.utc_now()}
  end

  defp caller_agent do
    # Best-effort: extract an agent label from the calling process dictionary.
    Process.get(:osa_agent_id, "unknown")
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  defp build_stats(state) do
    %{
      team_id: state.team_id,
      keeper_id: state.keeper_id,
      message_count: length(state.messages),
      token_count: state.token_count,
      dirty: state.dirty,
      access_patterns: state.access_patterns,
      created_at: state.created_at,
      last_accessed_at: state.last_accessed_at
    }
  end

  # ---------------------------------------------------------------------------
  # Token estimation
  # ---------------------------------------------------------------------------

  # 1 token per 4 characters + 4 overhead per message (role framing)
  defp estimate_tokens(%{content: content}) when is_binary(content) do
    estimate_tokens_text(content) + 4
  end

  defp estimate_tokens(%{"content" => content}) when is_binary(content) do
    estimate_tokens_text(content) + 4
  end

  defp estimate_tokens(_), do: 4

  defp estimate_tokens_text(nil), do: 0
  defp estimate_tokens_text(""), do: 0
  defp estimate_tokens_text(text) when is_binary(text), do: div(byte_size(text), 4) + 1

  # ---------------------------------------------------------------------------
  # Keyword scoring
  # ---------------------------------------------------------------------------

  defp tokenise_query(""), do: MapSet.new()

  defp tokenise_query(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp keyword_score(_msg, words) when map_size(words) == 0, do: 0.0

  defp keyword_score(msg, query_words) do
    content = Map.get(msg, :content) || Map.get(msg, "content") || ""

    msg_words =
      content
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    overlap = MapSet.intersection(query_words, msg_words) |> MapSet.size()
    total = MapSet.size(query_words)
    if total == 0, do: 0.0, else: overlap / total
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp clean_messages(messages) do
    Enum.map(messages, fn msg ->
      msg
      |> Map.delete(:__tokens)
      |> Map.delete(:__summarised_at)
    end)
  end

  defp format_messages_for_llm(messages) do
    messages
    |> Enum.map(fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role") || "unknown"
      content = Map.get(msg, :content) || Map.get(msg, "content") || ""
      "#{role}: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp via(team_id, keeper_id) do
    {:via, Registry, {OptimalSystemAgent.ContextMesh.KeeperRegistry, {team_id, keeper_id}}}
  end

  @type retrieval_mode :: :keyword | :smart | :full
end
