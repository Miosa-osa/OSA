defmodule OptimalSystemAgent.Agent.Cortex do
  @moduledoc """
  Knowledge synthesis engine — produces targeted memory bulletins and tracks cross-session patterns.

  Instead of summarizing ALL of memory into a 200-word blob, the Cortex:

  1. **Tracks active topics** across recent sessions using keyword frequency analysis
  2. **Generates targeted bulletins** with structured sections:
     - Current Focus, Pending Items, Key Decisions, Patterns, Context
  3. **Detects cross-session patterns** (recurring topics, communication style shifts)
  4. **Maintains per-session summaries** for fast cross-session awareness

  The synthesis runs on a configurable interval (default 5 minutes).
  `bulletin/0` is a fast read of cached state — safe to call on every
  context build. `refresh/0` forces an immediate re-synthesis.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.PromptLoader

  @default_refresh_interval 300_000
  @boot_delay 30_000
  @max_recent_sessions 5
  @topic_ets_table :osa_cortex_topics

  @synthesis_prompt_fallback """
  You are a knowledge synthesis engine for an AI agent called OSA (Optimal System Agent). Based on the following context, produce a structured bulletin that will be injected into the agent's system prompt.

  ## Active Sessions (most recent)
  %SESSION_SECTION%

  ## Long-term Memory (recent entries)
  %TRIMMED_MEMORY%

  ## Detected Active Topics
  %TOPICS_SECTION%

  Produce a bulletin with EXACTLY these sections. Be concise and actionable — the agent reads this before every response.

  1. **Current Focus**: What is the user actively working on right now? (1-3 bullets)
  2. **Pending Items**: Any open questions, unfinished tasks, or follow-ups needed? (1-3 bullets)
  3. **Key Decisions**: Recent decisions or preferences that should inform responses (1-3 bullets)
  4. **Patterns**: Notable patterns — recurring topics, workflow habits, communication preferences (1-2 bullets)
  5. **Context**: Important background facts the agent should keep in mind (1-2 bullets)

  Keep each section to 1-3 bullet points maximum. Total bulletin should be under 300 words.
  If a section has no relevant content, write "None detected" for that section.
  Do NOT include the raw data — synthesize it into actionable intelligence.
  """

  defstruct bulletin: nil,
            active_topics: [],
            session_summaries: %{},
            last_refresh: nil,
            refresh_interval: @default_refresh_interval,
            timer_ref: nil

  # ────────────────────────────────────────────────────────────────────
  # Public API
  # ────────────────────────────────────────────────────────────────────

  @doc """
  Returns the current memory bulletin string, or nil if none is available.
  Fast call — reads cached GenServer state only.
  """
  @spec bulletin() :: String.t() | nil
  def bulletin do
    GenServer.call(__MODULE__, :bulletin)
  end

  @doc """
  Force an immediate bulletin refresh. Returns :ok immediately;
  the synthesis happens asynchronously.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc """
  Get active topics detected across recent sessions.
  Returns a list of `%{topic: String.t(), frequency: integer(), last_seen: String.t()}`.
  """
  @spec active_topics() :: [map()]
  def active_topics do
    GenServer.call(__MODULE__, :active_topics)
  end

  @doc """
  Get a one-line summary of a specific session.
  Returns the cached summary string, or nil if not yet summarized.
  """
  @spec session_summary(String.t()) :: String.t() | nil
  def session_summary(session_id) do
    GenServer.call(__MODULE__, {:session_summary, session_id})
  end

  @doc """
  Get synthesis statistics: last refresh time, bulletin size, topic count, etc.
  """
  @spec synthesis_stats() :: map()
  def synthesis_stats do
    GenServer.call(__MODULE__, :synthesis_stats)
  end

  # ────────────────────────────────────────────────────────────────────
  # GenServer Lifecycle
  # ────────────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval =
      Application.get_env(
        :optimal_system_agent,
        :cortex_refresh_interval,
        @default_refresh_interval
      )

    # Create ETS table for topic tracking
    ensure_topic_table()

    timer_ref = Process.send_after(self(), :refresh, @boot_delay)

    state = %__MODULE__{
      refresh_interval: interval,
      timer_ref: timer_ref
    }

    Logger.info("Cortex started — first synthesis in #{@boot_delay}ms, interval #{interval}ms")
    {:ok, state}
  end

  # ────────────────────────────────────────────────────────────────────
  # Callbacks
  # ────────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:bulletin, _from, state) do
    {:reply, state.bulletin, state}
  end

  @impl true
  def handle_call(:active_topics, _from, state) do
    {:reply, state.active_topics, state}
  end

  @impl true
  def handle_call({:session_summary, session_id}, _from, state) do
    summary = Map.get(state.session_summaries, session_id)
    {:reply, summary, state}
  end

  @impl true
  def handle_call(:synthesis_stats, _from, state) do
    stats = %{
      last_refresh: state.last_refresh,
      bulletin_bytes: if(state.bulletin, do: byte_size(state.bulletin), else: 0),
      active_topic_count: length(state.active_topics),
      session_summaries_count: map_size(state.session_summaries),
      refresh_interval_ms: state.refresh_interval,
      has_bulletin: state.bulletin != nil
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state = cancel_timer(state)
    new_state = do_synthesis(state)
    timer_ref = Process.send_after(self(), :refresh, new_state.refresh_interval)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = cancel_timer(state)
    new_state = do_synthesis(state)
    timer_ref = Process.send_after(self(), :refresh, new_state.refresh_interval)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  # ────────────────────────────────────────────────────────────────────
  # Synthesis Engine
  # ────────────────────────────────────────────────────────────────────

  defp do_synthesis(state) do
    try do
      # 1. Gather raw material
      memory_content = Memory.recall()
      recent_sessions = get_recent_sessions(@max_recent_sessions)

      # 2. Extract active topics from memory + sessions
      active_topics = extract_topics(memory_content, recent_sessions)
      update_topic_table(active_topics)

      # 3. Generate/update session summaries for recent sessions
      session_summaries = update_session_summaries(state.session_summaries, recent_sessions)

      # 4. Build the synthesis
      if memory_content == "" and recent_sessions == [] do
        Logger.debug("Cortex: no material for synthesis, skipping")

        %{
          state
          | last_refresh: DateTime.utc_now(),
            active_topics: active_topics,
            session_summaries: session_summaries
        }
      else
        # Build targeted synthesis prompt
        messages =
          build_synthesis_messages(
            memory_content,
            recent_sessions,
            active_topics,
            session_summaries
          )

        case Providers.chat(messages, max_tokens: 500, temperature: 0.2) do
          {:ok, %{content: content}} when is_binary(content) and content != "" ->
            bulletin = String.trim(content)

            Logger.info(
              "Cortex: bulletin refreshed (#{byte_size(bulletin)} bytes), #{length(active_topics)} active topics"
            )

            %{
              state
              | bulletin: bulletin,
                active_topics: active_topics,
                session_summaries: session_summaries,
                last_refresh: DateTime.utc_now()
            }

          {:ok, %{content: _}} ->
            Logger.warning("Cortex: LLM returned empty content, keeping previous bulletin")

            %{
              state
              | active_topics: active_topics,
                session_summaries: session_summaries,
                last_refresh: DateTime.utc_now()
            }

          {:error, reason} ->
            Logger.warning(
              "Cortex: synthesis failed — #{inspect(reason)}, keeping previous bulletin"
            )

            %{
              state
              | active_topics: active_topics,
                session_summaries: session_summaries,
                last_refresh: DateTime.utc_now()
            }
        end
      end
    rescue
      e ->
        Logger.error("Cortex: synthesis crashed — #{inspect(e)}")
        %{state | last_refresh: DateTime.utc_now()}
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Topic Extraction
  # ────────────────────────────────────────────────────────────────────

  defp extract_topics(memory_content, recent_sessions) do
    # Extract keywords from memory
    memory_keywords =
      if memory_content != "" do
        Memory.extract_keywords(memory_content)
      else
        []
      end

    # Extract keywords from recent session content
    session_keywords =
      Enum.flat_map(recent_sessions, fn session ->
        session[:messages]
        |> Enum.filter(fn msg -> msg["role"] == "user" end)
        |> Enum.flat_map(fn msg ->
          Memory.extract_keywords(msg["content"] || "")
        end)
      end)

    # Count frequencies — session keywords weighted 2x (more recent/relevant)
    frequencies =
      Enum.reduce(memory_keywords, %{}, fn kw, acc ->
        Map.update(acc, kw, 1, &(&1 + 1))
      end)

    frequencies =
      Enum.reduce(session_keywords, frequencies, fn kw, acc ->
        Map.update(acc, kw, 2, &(&1 + 2))
      end)

    # Filter to meaningful topics: frequency >= 2 and not too generic
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    frequencies
    |> Enum.filter(fn {_kw, freq} -> freq >= 2 end)
    |> Enum.sort_by(fn {_kw, freq} -> freq end, :desc)
    |> Enum.take(15)
    |> Enum.map(fn {topic, frequency} ->
      %{topic: topic, frequency: frequency, last_seen: now}
    end)
  end

  # ────────────────────────────────────────────────────────────────────
  # Session Summaries
  # ────────────────────────────────────────────────────────────────────

  defp update_session_summaries(existing_summaries, recent_sessions) do
    Enum.reduce(recent_sessions, existing_summaries, fn session, acc ->
      session_id = session[:session_id]

      # Only re-summarize if we don't have a summary yet,
      # or the session has grown significantly
      current_summary = Map.get(acc, session_id)

      if current_summary == nil and session[:messages] != [] do
        summary = generate_local_summary(session)
        Map.put(acc, session_id, summary)
      else
        acc
      end
    end)
  end

  defp generate_local_summary(session) do
    # Generate a one-line summary from the session without calling an LLM.
    # Use the first user message and count of exchanges.
    messages = session[:messages] || []
    user_messages = Enum.filter(messages, fn m -> m["role"] == "user" end)

    first_topic =
      case user_messages do
        [first | _] ->
          content = first["content"] || ""
          content |> String.slice(0, 100) |> String.trim()

        [] ->
          "empty session"
      end

    exchange_count = length(user_messages)
    "#{exchange_count} exchange(s) — #{first_topic}"
  end

  # ────────────────────────────────────────────────────────────────────
  # Recent Sessions Loader
  # ────────────────────────────────────────────────────────────────────

  defp get_recent_sessions(count) do
    try do
      sessions = Memory.list_sessions()

      sessions
      |> Enum.take(count)
      |> Enum.map(fn session_meta ->
        messages =
          case Memory.load_session(session_meta.session_id) do
            msgs when is_list(msgs) -> msgs
            _ -> []
          end

        Map.put(session_meta, :messages, messages)
      end)
    rescue
      _ -> []
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Synthesis Prompt
  # ────────────────────────────────────────────────────────────────────

  defp build_synthesis_messages(memory_content, recent_sessions, active_topics, session_summaries) do
    # Trim memory content to avoid overflowing context
    trimmed_memory = trim_content(memory_content, 3000)

    # Format recent session summaries
    session_section =
      if recent_sessions != [] do
        recent_sessions
        |> Enum.map(fn session ->
          sid = session[:session_id] || "unknown"
          summary = Map.get(session_summaries, sid, "no summary")
          last = session[:last_active] || "unknown"
          "- **#{sid}** (last active: #{last}): #{summary}"
        end)
        |> Enum.join("\n")
      else
        "No recent sessions."
      end

    # Format active topics
    topics_section =
      if active_topics != [] do
        active_topics
        |> Enum.map(fn t -> "- #{t.topic} (frequency: #{t.frequency})" end)
        |> Enum.join("\n")
      else
        "No active topics detected yet."
      end

    template = PromptLoader.get(:cortex_synthesis, @synthesis_prompt_fallback)

    prompt =
      template
      |> String.replace("%SESSION_SECTION%", session_section)
      |> String.replace("%TRIMMED_MEMORY%", trimmed_memory)
      |> String.replace("%TOPICS_SECTION%", topics_section)

    [%{role: "user", content: prompt}]
  end

  defp trim_content(content, max_chars) when is_binary(content) do
    if byte_size(content) > max_chars do
      # Take the last max_chars worth of content (most recent entries are at the end)
      binary_part(
        content,
        max(byte_size(content) - max_chars, 0),
        min(max_chars, byte_size(content))
      )
    else
      content
    end
  end

  defp trim_content(_, _max_chars), do: ""

  # ────────────────────────────────────────────────────────────────────
  # ETS Topic Table
  # ────────────────────────────────────────────────────────────────────

  defp ensure_topic_table do
    case :ets.info(@topic_ets_table) do
      :undefined ->
        :ets.new(@topic_ets_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp update_topic_table(active_topics) do
    try do
      ensure_topic_table()
      :ets.delete_all_objects(@topic_ets_table)

      Enum.each(active_topics, fn topic ->
        :ets.insert(@topic_ets_table, {topic.topic, topic})
      end)
    rescue
      _ -> :ok
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Helpers
  # ────────────────────────────────────────────────────────────────────

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
