defmodule OptimalSystemAgent.Agent.Memory do
  @moduledoc """
  Intelligent persistent memory — three-store architecture with relevance-based retrieval.

  ## Three Memory Stores

  1. **Session Memory** (JSONL per session)
     `~/.osa/sessions/{session_id}.jsonl`
     Append-only conversation history. Load by session ID for continuity.

  2. **Long-term Memory** (MEMORY.md)
     `~/.osa/MEMORY.md`
     Consolidated insights, decisions, preferences.
     Structured with categories and timestamps, searchable by keyword and category.

  3. **Episodic Index** (ETS)
     In-memory inverted keyword index built from MEMORY.md on startup.
     Maps keywords to memory entry IDs for fast relevant-memory lookup.
     Rebuilt on each remember/archive operation.

  ## Key Design Decisions

  - `recall/0` still returns the full MEMORY.md contents for backward compatibility.
  - `recall_relevant/2` is the smart path: extracts keywords from a query,
    looks them up in the ETS index, scores by relevance + recency, and returns
    only the top entries that fit within a token budget.
  - `search/2` provides keyword and category search with sorting options.
  - `archive/1` moves old low-importance entries to dated archive files.
  """
  use GenServer
  require Logger
  alias OptimalSystemAgent.Store.{Repo, Message}

  # Resolve at runtime to avoid baking in compile-host paths (/Users/runner/.osa)
  defp sessions_dir do
    Application.get_env(:optimal_system_agent, :sessions_dir, "~/.osa/sessions")
    |> Path.expand()
  end

  defp osa_dir do
    Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
    |> Path.expand()
  end

  @index_table :osa_memory_index
  @entry_table :osa_memory_entries

  # Common English stop words to exclude from keyword extraction
  @stop_words MapSet.new(~w(
    the and for are but not you all any can had her was one our out day been have
    from this that with what when will more about which them than been would make
    like time just know take people into year your good some could over such after
    come made find back only first great even give most those down should well
    being work through where much other also life between know years hand high
    because large turn each long next look state want head around move both
    think still might school world kind keep never really need does going right
    used every last very just said same tell call before mean also actually thing
    many then those however these while most only must since well still under
    again too own part here there where help using really trying getting doing
    went got let its use way may new now old see try run put set did get how
    has him his she her its who why yes yet able
  ))

  # Importance multipliers by category
  @category_importance %{
    "decision" => 1.0,
    "preference" => 0.9,
    "architecture" => 0.95,
    "bug" => 0.8,
    "insight" => 0.85,
    "contact" => 0.7,
    "workflow" => 0.75,
    "general" => 0.5,
    "note" => 0.4
  }

  # Approximate tokens per character (conservative estimate)
  @chars_per_token 4

  # ────────────────────────────────────────────────────────────────────
  # Public API
  # ────────────────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Append a message to a session's JSONL file."
  def append(session_id, entry) when is_map(entry) do
    GenServer.cast(__MODULE__, {:append, session_id, entry})
  end

  @doc "Load a session's message history."
  def load_session(session_id) do
    GenServer.call(__MODULE__, {:load, session_id})
  end

  @doc "Save a key insight to MEMORY.md with importance scoring."
  def remember(content, category \\ "general") do
    GenServer.cast(__MODULE__, {:remember, content, category})
  end

  @doc "Read current MEMORY.md contents (full dump, backward-compatible)."
  def recall do
    GenServer.call(__MODULE__, :recall)
  end

  @doc """
  Retrieve memories RELEVANT to the given message/query.

  Instead of loading all of MEMORY.md, this function:
  1. Extracts keywords from the input message
  2. Looks up keywords in the ETS inverted index
  3. Scores each matching entry by relevance (keyword overlap + recency + importance)
  4. Returns top entries that fit within the max_tokens budget
  5. Formats as a coherent context block

  Returns a string of relevant memory content, or "" if nothing matches.
  """
  @spec recall_relevant(String.t(), pos_integer()) :: String.t()
  def recall_relevant(message, max_tokens \\ 2000) do
    GenServer.call(__MODULE__, {:recall_relevant, message, max_tokens})
  end

  @doc """
  Search memories by keyword or category.

  ## Options
    - `:category` - Filter by category (e.g., "decision", "preference")
    - `:limit` - Maximum number of results (default 10)
    - `:sort` - Sort order: `:relevance` (default), `:recency`, `:importance`

  Returns a list of memory entry maps sorted by the chosen criterion.
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    GenServer.call(__MODULE__, {:search, query, opts})
  end

  @doc """
  Archive old low-importance memories.

  Moves entries older than `max_age_days` with importance below 0.7
  to `~/.osa/archive/MEMORY-{date}.md`. Rebuilds the index afterward.

  Returns `{:ok, archived_count}` or `{:error, reason}`.
  """
  @spec archive(pos_integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def archive(max_age_days \\ 30) do
    GenServer.call(__MODULE__, {:archive, max_age_days})
  end

  @doc """
  Get memory statistics: entry count, categories, index size, file sizes, etc.
  """
  @spec memory_stats() :: map()
  def memory_stats do
    GenServer.call(__MODULE__, :memory_stats)
  end

  @doc """
  List all session IDs with metadata (last active, message count, topic hint).
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @doc """
  Resume a previous session — returns its history for re-injection into a loop.
  """
  @spec resume_session(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def resume_session(session_id) do
    GenServer.call(__MODULE__, {:resume_session, session_id})
  end

  @doc "Search messages across all sessions."
  @spec search_messages(String.t(), keyword()) :: [map()]
  def search_messages(query, opts \\ []) do
    GenServer.call(__MODULE__, {:search_messages, query, opts})
  end

  @doc "Get statistics for a specific session."
  @spec session_stats(String.t()) :: map()
  def session_stats(session_id) do
    GenServer.call(__MODULE__, {:session_stats, session_id})
  end

  # ────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ────────────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    dir = sessions_dir()
    File.mkdir_p!(dir)

    # Create ETS tables for the episodic index
    ensure_ets_tables()

    # Build the initial index from MEMORY.md
    build_index()

    Logger.info("Agent.Memory started — sessions at #{dir}, index built")
    {:ok, %{sessions_dir: dir}}
  end

  # ── Casts ──────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:append, session_id, entry}, state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # JSONL write (backward compat)
    path = session_path(state.sessions_dir, session_id)
    line = Jason.encode!(Map.put(entry, :timestamp, timestamp))
    File.write!(path, line <> "\n", [:append, :utf8])

    # SQLite write (new)
    persist_to_sqlite(session_id, entry, timestamp)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:remember, content, category}, state) do
    memory_file = memory_file_path()
    File.mkdir_p!(Path.dirname(memory_file))
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    entry = "\n## [#{category}] #{timestamp}\n#{content}\n"
    File.write!(memory_file, entry, [:append, :utf8])

    # Rebuild the index to include the new entry
    build_index()

    {:noreply, state}
  end

  # ── Calls ──────────────────────────────────────────────────────────

  @impl true
  def handle_call({:load, session_id}, _from, state) do
    messages = load_from_sqlite(session_id) || load_from_jsonl(state.sessions_dir, session_id)
    {:reply, messages, state}
  end

  @impl true
  def handle_call(:recall, _from, state) do
    content =
      if File.exists?(memory_file_path()) do
        File.read!(memory_file_path())
      else
        ""
      end

    {:reply, content, state}
  end

  @impl true
  def handle_call({:recall_relevant, message, max_tokens}, _from, state) do
    result = do_recall_relevant(message, max_tokens)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    result = do_search(query, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:archive, max_age_days}, _from, state) do
    result = do_archive(max_age_days)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:memory_stats, _from, state) do
    stats = do_memory_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions = do_list_sessions(state.sessions_dir)
    {:reply, sessions, state}
  end

  @impl true
  def handle_call({:resume_session, session_id}, _from, state) do
    path = session_path(state.sessions_dir, session_id)

    if File.exists?(path) do
      messages =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, msg} -> msg
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:reply, {:ok, messages}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:search_messages, query, opts}, _from, state) do
    result = do_search_messages(query, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:session_stats, session_id}, _from, state) do
    result = do_session_stats(session_id)
    {:reply, result, state}
  end

  # ────────────────────────────────────────────────────────────────────
  # Intelligent Retrieval
  # ────────────────────────────────────────────────────────────────────

  defp do_recall_relevant(message, max_tokens) do
    # Try semantic search first (Python sidecar), fall back to keyword search
    case try_semantic_search(message, max_tokens) do
      {:ok, results} when results != "" -> results
      _ -> do_recall_relevant_keyword(message, max_tokens)
    end
  end

  defp try_semantic_search(message, _max_tokens) do
    if Application.get_env(:optimal_system_agent, :python_sidecar_enabled, false) do
      alias OptimalSystemAgent.Python.Embeddings

      if Embeddings.available?() do
        case Embeddings.search(message, top_k: 10) do
          {:ok, results} when is_list(results) and results != [] ->
            # Look up full entries by ID and format them
            formatted =
              results
              |> Enum.map(fn %{"id" => id, "score" => score} ->
                case :ets.lookup(@entry_table, id) do
                  [{^id, entry}] ->
                    header =
                      "## [#{entry[:category] || "general"}] #{entry[:timestamp] || "unknown"}"

                    "#{header} (relevance: #{score})\n#{entry[:content] || ""}\n"

                  [] ->
                    nil
                end
              end)
              |> Enum.reject(&is_nil/1)
              |> Enum.join("\n")

            if formatted == "", do: {:error, :no_results}, else: {:ok, formatted}

          _ ->
            {:error, :no_results}
        end
      else
        {:error, :unavailable}
      end
    else
      {:error, :disabled}
    end
  rescue
    _ -> {:error, :exception}
  end

  defp do_recall_relevant_keyword(message, max_tokens) do
    keywords = extract_keywords(message)

    if keywords == [] do
      # Fall back to most recent entries if no keywords extracted
      get_recent_entries(max_tokens)
    else
      # Look up each keyword in the inverted index, collect entry IDs
      entry_ids =
        keywords
        |> Enum.flat_map(fn keyword ->
          case :ets.lookup(@index_table, keyword) do
            [{^keyword, ids}] -> ids
            [] -> []
          end
        end)
        |> Enum.frequencies()

      if map_size(entry_ids) == 0 do
        get_recent_entries(max_tokens)
      else
        # Score and rank entries
        scored =
          entry_ids
          |> Enum.map(fn {entry_id, keyword_hits} ->
            case :ets.lookup(@entry_table, entry_id) do
              [{^entry_id, entry}] ->
                score = compute_relevance_score(entry, keyword_hits, length(keywords))
                {score, entry}

              [] ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(fn {score, _entry} -> score end, :desc)

        # Select entries within token budget
        max_chars = max_tokens * @chars_per_token
        select_within_budget(scored, max_chars)
      end
    end
  end

  defp compute_relevance_score(entry, keyword_hits, total_keywords) do
    # Keyword overlap ratio (0.0 to 1.0)
    overlap = keyword_hits / max(total_keywords, 1)

    # Recency boost: entries from last 24h get 1.0, decaying over time
    recency =
      case entry[:timestamp] do
        nil ->
          0.3

        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _offset} ->
              age_hours = DateTime.diff(DateTime.utc_now(), dt, :second) / 3600.0
              # Exponential decay with half-life of 48 hours
              :math.exp(-0.693 * age_hours / 48.0)

            _ ->
              0.3
          end

        _ ->
          0.3
      end

    # Category importance
    importance = Map.get(@category_importance, entry[:category] || "general", 0.5)

    # Weighted combination
    overlap * 0.5 + recency * 0.3 + importance * 0.2
  end

  defp select_within_budget(scored_entries, max_chars) do
    {selected, _remaining_budget} =
      Enum.reduce_while(scored_entries, {[], max_chars}, fn {_score, entry}, {acc, budget} ->
        content = entry[:content] || ""
        header = "## [#{entry[:category] || "general"}] #{entry[:timestamp] || "unknown"}"
        full_text = "#{header}\n#{content}\n"
        text_size = byte_size(full_text)

        if text_size <= budget do
          {:cont, {[full_text | acc], budget - text_size}}
        else
          {:halt, {acc, budget}}
        end
      end)

    selected
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp get_recent_entries(max_tokens) do
    # Grab the last N entries from the entry table, sorted by timestamp descending
    max_chars = max_tokens * @chars_per_token

    entries =
      try do
        :ets.tab2list(@entry_table)
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.sort_by(fn entry -> entry[:timestamp] || "" end, :desc)
        |> Enum.take(20)
      rescue
        _ -> []
      end

    scored = Enum.map(entries, fn entry -> {1.0, entry} end)
    select_within_budget(scored, max_chars)
  end

  # ────────────────────────────────────────────────────────────────────
  # Search
  # ────────────────────────────────────────────────────────────────────

  defp do_search(query, opts) do
    category_filter = Keyword.get(opts, :category)
    limit = Keyword.get(opts, :limit, 10)
    sort = Keyword.get(opts, :sort, :relevance)

    keywords = extract_keywords(query)

    # Collect all entries
    all_entries =
      try do
        :ets.tab2list(@entry_table)
        |> Enum.map(fn {_id, entry} -> entry end)
      rescue
        _ -> []
      end

    # Apply category filter
    filtered =
      if category_filter do
        Enum.filter(all_entries, fn entry ->
          entry[:category] == category_filter
        end)
      else
        all_entries
      end

    # Score each entry if we have keywords
    scored =
      if keywords != [] do
        Enum.map(filtered, fn entry ->
          entry_keywords = extract_keywords(entry[:content] || "")
          overlap = length(keywords -- (keywords -- entry_keywords))
          score = compute_relevance_score(entry, overlap, length(keywords))
          {score, entry}
        end)
        |> Enum.filter(fn {score, _} -> score > 0.05 end)
      else
        Enum.map(filtered, fn entry -> {0.5, entry} end)
      end

    # Sort
    sorted =
      case sort do
        :relevance ->
          Enum.sort_by(scored, fn {score, _} -> score end, :desc)

        :recency ->
          Enum.sort_by(scored, fn {_, entry} -> entry[:timestamp] || "" end, :desc)

        :importance ->
          Enum.sort_by(
            scored,
            fn {_, entry} ->
              Map.get(@category_importance, entry[:category] || "general", 0.5)
            end,
            :desc
          )

        _ ->
          Enum.sort_by(scored, fn {score, _} -> score end, :desc)
      end

    sorted
    |> Enum.take(limit)
    |> Enum.map(fn {score, entry} -> Map.put(entry, :relevance_score, Float.round(score, 3)) end)
  end

  # ────────────────────────────────────────────────────────────────────
  # Archival
  # ────────────────────────────────────────────────────────────────────

  defp do_archive(max_age_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 86_400, :second)

    all_entries =
      try do
        :ets.tab2list(@entry_table)
        |> Enum.map(fn {id, entry} -> {id, entry} end)
      rescue
        _ -> []
      end

    # Partition into keep vs archive
    {to_archive, to_keep} =
      Enum.split_with(all_entries, fn {_id, entry} ->
        importance = Map.get(@category_importance, entry[:category] || "general", 0.5)
        old_enough = entry_before_cutoff?(entry, cutoff)
        old_enough and importance < 0.7
      end)

    if to_archive == [] do
      {:ok, 0}
    else
      try do
        # Write archived entries to dated archive file
        archive_dir = Path.join(osa_dir(), "archive")
        File.mkdir_p!(archive_dir)
        date_str = Date.utc_today() |> Date.to_iso8601()
        archive_path = Path.join(archive_dir, "MEMORY-#{date_str}.md")

        archive_content =
          to_archive
          |> Enum.map(fn {_id, entry} ->
            "## [#{entry[:category] || "general"}] #{entry[:timestamp] || "unknown"}\n#{entry[:content] || ""}\n"
          end)
          |> Enum.join("\n")

        File.write!(archive_path, archive_content, [:append, :utf8])

        # Rewrite MEMORY.md with only kept entries
        kept_content =
          to_keep
          |> Enum.sort_by(fn {_id, entry} -> entry[:timestamp] || "" end)
          |> Enum.map(fn {_id, entry} ->
            "## [#{entry[:category] || "general"}] #{entry[:timestamp] || "unknown"}\n#{entry[:content] || ""}\n"
          end)
          |> Enum.join("\n")

        File.write!(memory_file_path(), kept_content, [:utf8])

        # Rebuild index
        build_index()

        Logger.info(
          "Memory archived #{length(to_archive)} entries to #{archive_path}, kept #{length(to_keep)}"
        )

        {:ok, length(to_archive)}
      rescue
        e ->
          Logger.error("Memory archive failed: #{inspect(e)}")
          {:error, "Archive failed: #{inspect(e)}"}
      end
    end
  end

  defp entry_before_cutoff?(entry, cutoff) do
    case entry[:timestamp] do
      nil ->
        true

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _offset} -> DateTime.compare(dt, cutoff) == :lt
          _ -> true
        end

      _ ->
        true
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Memory Stats
  # ────────────────────────────────────────────────────────────────────

  defp do_memory_stats(state) do
    entry_count =
      try do
        :ets.info(@entry_table, :size) || 0
      rescue
        _ -> 0
      end

    index_count =
      try do
        :ets.info(@index_table, :size) || 0
      rescue
        _ -> 0
      end

    memory_file_size =
      if File.exists?(memory_file_path()) do
        case File.stat(memory_file_path()) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end
      else
        0
      end

    # Count entries per category
    categories =
      try do
        :ets.tab2list(@entry_table)
        |> Enum.map(fn {_id, entry} -> entry[:category] || "general" end)
        |> Enum.frequencies()
      rescue
        _ -> %{}
      end

    # Session count
    session_count =
      if File.exists?(state.sessions_dir) do
        case File.ls(state.sessions_dir) do
          {:ok, files} -> Enum.count(files, &String.ends_with?(&1, ".jsonl"))
          _ -> 0
        end
      else
        0
      end

    %{
      entry_count: entry_count,
      index_keywords: index_count,
      memory_file_bytes: memory_file_size,
      categories: categories,
      session_count: session_count,
      sessions_dir: state.sessions_dir,
      memory_file: memory_file_path()
    }
  end

  # ────────────────────────────────────────────────────────────────────
  # Session Listing
  # ────────────────────────────────────────────────────────────────────

  defp do_list_sessions(sessions_dir) do
    if File.exists?(sessions_dir) do
      case File.ls(sessions_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(fn filename ->
            session_id = String.trim_trailing(filename, ".jsonl")
            path = Path.join(sessions_dir, filename)
            extract_session_metadata(session_id, path)
          end)
          |> Enum.sort_by(& &1.last_active, :desc)

        _ ->
          []
      end
    else
      []
    end
  end

  defp extract_session_metadata(session_id, path) do
    try do
      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      message_count = length(lines)

      # Parse first line for start time and topic hint
      {first_timestamp, topic_hint} =
        case lines do
          [first | _] ->
            case Jason.decode(first) do
              {:ok, msg} ->
                ts = Map.get(msg, "timestamp", nil)

                topic =
                  case Map.get(msg, "content") do
                    c when is_binary(c) and byte_size(c) > 0 ->
                      c |> String.slice(0, 80) |> String.trim()

                    _ ->
                      nil
                  end

                {ts, topic}

              _ ->
                {nil, nil}
            end

          [] ->
            {nil, nil}
        end

      # Parse last line for end time
      last_timestamp =
        case List.last(lines) do
          nil ->
            nil

          last ->
            case Jason.decode(last) do
              {:ok, msg} -> Map.get(msg, "timestamp", nil)
              _ -> nil
            end
        end

      %{
        session_id: session_id,
        message_count: message_count,
        first_active: first_timestamp,
        last_active: last_timestamp || first_timestamp,
        topic_hint: topic_hint
      }
    rescue
      _ ->
        %{
          session_id: session_id,
          message_count: 0,
          first_active: nil,
          last_active: nil,
          topic_hint: nil
        }
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # ETS Index Management
  # ────────────────────────────────────────────────────────────────────

  defp ensure_ets_tables do
    # Inverted keyword index: keyword => [entry_id, ...]
    case :ets.info(@index_table) do
      :undefined ->
        :ets.new(@index_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end

    # Entry store: entry_id => entry_map
    case :ets.info(@entry_table) do
      :undefined ->
        :ets.new(@entry_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp build_index do
    ensure_ets_tables()

    try do
      :ets.delete_all_objects(@index_table)
      :ets.delete_all_objects(@entry_table)

      content =
        if File.exists?(memory_file_path()) do
          File.read!(memory_file_path())
        else
          ""
        end

      if content != "" do
        entries = parse_memory_entries(content)

        Enum.each(entries, fn {entry_id, entry} ->
          # Store the full entry
          :ets.insert(@entry_table, {entry_id, entry})

          # Index keywords from the content
          keywords = extract_keywords(entry[:content] || "")

          # Also index the category itself
          category_kw =
            if entry[:category], do: [String.downcase(entry[:category])], else: []

          all_keywords = Enum.uniq(keywords ++ category_kw)

          Enum.each(all_keywords, fn keyword ->
            existing =
              case :ets.lookup(@index_table, keyword) do
                [{^keyword, ids}] -> ids
                [] -> []
              end

            :ets.insert(@index_table, {keyword, [entry_id | existing]})
          end)
        end)

        entry_count = length(entries)
        keyword_count = :ets.info(@index_table, :size) || 0
        Logger.debug("Memory index built: #{entry_count} entries, #{keyword_count} keywords")
      end
    rescue
      e ->
        Logger.error("Failed to build memory index: #{inspect(e)}")
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # MEMORY.md Parsing
  # ────────────────────────────────────────────────────────────────────

  @doc false
  def parse_memory_entries(content) do
    # Parse entries in the format:
    # ## [category] 2026-02-27T10:30:00Z
    # Content spanning multiple lines...

    entry_regex = ~r/^## \[([^\]]+)\]\s+(.+)$/m

    # Split on entry headers, keeping the headers
    parts = Regex.split(entry_regex, content, include_captures: true, trim: true)

    parse_entry_parts(parts, [])
  end

  defp parse_entry_parts([], acc), do: Enum.reverse(acc)

  defp parse_entry_parts([potential_header | rest], acc) do
    case Regex.run(~r/^## \[([^\]]+)\]\s+(.+)$/, String.trim(potential_header)) do
      [_full, category, timestamp_str] ->
        # The next element (if any) is the content until next header
        {content, remaining} =
          case rest do
            [body | tail] ->
              # Check if body is itself a header
              if Regex.match?(~r/^## \[/, String.trim(body)) do
                {"", rest}
              else
                {String.trim(body), tail}
              end

            [] ->
              {"", []}
          end

        entry_id = generate_entry_id(category, timestamp_str, content)

        importance =
          compute_importance(category, content)

        entry = %{
          id: entry_id,
          category: category,
          timestamp: timestamp_str,
          content: content,
          importance: importance
        }

        parse_entry_parts(remaining, [{entry_id, entry} | acc])

      nil ->
        # Not a header line — skip preamble text
        parse_entry_parts(rest, acc)
    end
  end

  defp generate_entry_id(category, timestamp, content) do
    data = "#{category}:#{timestamp}:#{content}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp compute_importance(category, content) do
    base = Map.get(@category_importance, String.downcase(category), 0.5)

    # Boost for longer, more detailed entries
    length_boost =
      cond do
        byte_size(content) > 500 -> 0.1
        byte_size(content) > 200 -> 0.05
        true -> 0.0
      end

    # Boost for entries with technical terms (heuristic: contains code-like patterns)
    technical_boost =
      if Regex.match?(~r/[A-Z][a-z]+[A-Z]|[a-z]+_[a-z]+|->|=>|\(\)|def |fn /, content) do
        0.05
      else
        0.0
      end

    min(base + length_boost + technical_boost, 1.0)
  end

  # ────────────────────────────────────────────────────────────────────
  # Keyword Extraction
  # ────────────────────────────────────────────────────────────────────

  @doc false
  def extract_keywords(message) do
    message
    |> String.downcase()
    |> String.replace(~r/[`"'{}()\[\]]/, " ")
    |> String.split(~r/[\s,.\-:;!?\/\\|@#$%^&*+=<>~]+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(@stop_words, word) end)
    |> Enum.filter(fn word -> String.length(word) > 2 end)
    |> Enum.reject(fn word -> Regex.match?(~r/^\d+$/, word) end)
    |> Enum.uniq()
  end

  # ────────────────────────────────────────────────────────────────────
  # Helpers
  # ────────────────────────────────────────────────────────────────────

  defp session_path(dir, session_id) do
    Path.join(dir, "#{session_id}.jsonl")
  end

  defp memory_file_path do
    Path.join(osa_dir(), "MEMORY.md")
  end

  # ────────────────────────────────────────────────────────────────────
  # SQLite Persistence
  # ────────────────────────────────────────────────────────────────────

  defp persist_to_sqlite(session_id, entry, _timestamp) do
    attrs = %{
      session_id: session_id,
      role: to_string(Map.get(entry, :role, Map.get(entry, "role", "user"))),
      content: to_string(Map.get(entry, :content, Map.get(entry, "content", ""))),
      tool_calls: Map.get(entry, :tool_calls, Map.get(entry, "tool_calls")),
      tool_call_id: Map.get(entry, :tool_call_id, Map.get(entry, "tool_call_id")),
      signal_mode: Map.get(entry, :signal_mode, Map.get(entry, "signal_mode")),
      signal_weight: parse_float(Map.get(entry, :signal_weight, Map.get(entry, "signal_weight"))),
      token_count: parse_int(Map.get(entry, :token_count, Map.get(entry, "token_count"))),
      channel: get_string(entry, :channel),
      metadata: Map.get(entry, :metadata, Map.get(entry, "metadata", %{}))
    }

    case Message.changeset(attrs) |> Repo.insert() do
      {:ok, _msg} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist message to SQLite: #{inspect(changeset.errors)}")
    end
  rescue
    e ->
      Logger.warning("SQLite write error: #{Exception.message(e)}")
  end

  defp load_from_sqlite(session_id) do
    import Ecto.Query

    messages =
      from(m in Message,
        where: m.session_id == ^session_id,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(fn msg ->
        # Return string-keyed maps for backward compat with JSONL format
        base = %{
          "role" => msg.role,
          "content" => msg.content,
          "timestamp" => NaiveDateTime.to_iso8601(msg.inserted_at)
        }

        base
        |> maybe_put("tool_calls", msg.tool_calls)
        |> maybe_put("tool_call_id", msg.tool_call_id)
        |> maybe_put("signal_mode", msg.signal_mode)
        |> maybe_put("signal_weight", msg.signal_weight)
        |> maybe_put("token_count", msg.token_count)
        |> maybe_put("channel", msg.channel)
      end)

    if messages == [], do: nil, else: messages
  rescue
    _ -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp load_from_jsonl(sessions_dir, session_id) do
    path = session_path(sessions_dir, session_id)

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Jason.decode(line) do
          {:ok, msg} -> msg
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp do_search_messages(query, opts) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 20)
    pattern = "%#{query}%"

    from(m in Message,
      where: like(m.content, ^pattern),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      select: %{
        id: m.id,
        session_id: m.session_id,
        role: m.role,
        content: m.content,
        inserted_at: m.inserted_at
      }
    )
    |> Repo.all()
  rescue
    e ->
      Logger.warning("Message search error: #{Exception.message(e)}")
      []
  end

  defp do_session_stats(session_id) do
    import Ecto.Query

    stats =
      from(m in Message,
        where: m.session_id == ^session_id,
        select: %{
          count: count(m.id),
          total_tokens: sum(m.token_count),
          first_at: min(m.inserted_at),
          last_at: max(m.inserted_at)
        }
      )
      |> Repo.one()

    role_counts =
      from(m in Message,
        where: m.session_id == ^session_id,
        group_by: m.role,
        select: {m.role, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.put(stats || %{}, :roles, role_counts)
  rescue
    _ -> %{count: 0, total_tokens: 0, roles: %{}}
  end

  defp parse_float(nil), do: nil
  defp parse_float(f) when is_float(f), do: f
  defp parse_float(i) when is_integer(i), do: i / 1.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp get_string(entry, key) do
    case Map.get(entry, key, Map.get(entry, to_string(key))) do
      nil -> nil
      val -> to_string(val)
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
