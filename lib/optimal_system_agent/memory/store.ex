defmodule OptimalSystemAgent.Memory.Store do
  @moduledoc """
  Memory storage engine — ETS cache + SQLite persistence.

  Manages two ETS tables:
    - `:osa_memory_index`   — keyword → [memory_id, ...] inverted index
    - `:osa_memory_entries` — id → entry map for O(1) reads after recall

  On startup the tables are populated from SQLite so restarts are warm.
  A periodic timer decays relevance scores for stale entries.

  All persistent writes go through Ecto to `OptimalSystemAgent.Store.Repo`.
  The Ecto schema used is `OptimalSystemAgent.Store.MemoryEntry`.

  ## Consolidation (Mem0-style)

  Before inserting a new entry, the Store checks for similar existing entries
  using keyword overlap scoring. Four outcomes are possible:

    - ADD    — no sufficiently-similar entry (overlap < @merge_threshold);
               insert as new, recording A-MEM links to keyword-adjacent entries
    - UPDATE — a highly-similar entry exists (overlap >= @merge_threshold and
               < @duplicate_threshold); merge content (growth-capped) and update
    - NOOP   — content is effectively identical (overlap >= @duplicate_threshold);
               skip the write
    - DELETE — (future) contradictory memory; remove the old one

  Note: the *candidate* threshold (`@similarity_threshold`, used for A-MEM
  linking) is intentionally LOWER than the *merge* threshold (`@merge_threshold`).
  Entries that merely share ~40% of keywords are linked, NOT merged — merging two
  distinct facts collapses them into a single garbled row and loses the new
  fact's id/category, which silently corrupts memory quality.

  ## Relevance scoring

  When recalling memories the score for each candidate entry is:

      score = (base_match * 0.30) + (signal_weight * 0.50) + (recency * 0.20)

  Where:
    - base_match   — fraction of query keywords found in entry keywords
    - signal_weight — stored signal importance (0.0–1.0)
    - recency      — 1.0 for entries < 1 day old, decaying to 0.0 over 30 days
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Store.{Repo, MemoryEntry}
  alias OptimalSystemAgent.Agent.Memory.SQLiteBridge
  import Ecto.Query

  @index_table :osa_memory_index
  @entries_table :osa_memory_entries

  # Decay timer fires every hour
  @decay_interval_ms 60 * 60 * 1_000

  # Minimum keyword overlap score to consider two entries "similar" — used ONLY
  # to gather candidates for A-MEM linking (do_save records links to these).
  @similarity_threshold 0.40

  # Overlap required to MERGE the new content into an existing entry. Deliberately
  # much higher than @similarity_threshold: below this the entries are merely
  # keyword-adjacent (distinct facts) and must be stored separately, not merged.
  @merge_threshold 0.75

  # Overlap at/above which the new content is treated as a duplicate (NOOP write).
  @duplicate_threshold 0.95

  # Growth cap: an entry whose content already exceeds this size is never appended
  # to again — a near-duplicate is stored as its own linked entry instead, so a
  # single row can't accumulate content forever.
  @max_merge_content_chars 4_000

  # When merging, keep only the base content plus the most recent N "Updated:"
  # refinement segments.
  @max_updated_segments 5

  # Delimiter separating the base content from appended refinement segments.
  @updated_delim "\n\nUpdated: "

  # Stop words excluded from keyword extraction
  @stop_words ~w(a an the and or but in on at to for of is are was were be been
                 being have has had do does did will would could should may might
                 this that these those i you he she it we they me him her us them
                 my your his its our their what which who when where how with from
                 by about into than then also just not no nor so yet both either
                 each other such while if as after before since until unless though
                 although because since while where whether can cannot am)

  # ---------------------------------------------------------------------------
  # Public start
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.info("[Memory.Store] starting")

    create_ets_tables()
    load_from_sqlite()

    schedule_decay()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:save, content, opts}, _from, state) do
    result = do_save(content, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:recall, query, opts}, _from, state) do
    result = do_recall(query, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    result = do_get(id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    result = do_recent(limit)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    result = do_delete(id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:search_sessions, query, opts}, _from, state) do
    results = SQLiteBridge.search_messages(query, opts)
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    result = do_stats()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:regenerate_md, _from, state) do
    result = write_memory_md()
    {:reply, result, state}
  end

  @impl true
  def handle_call(:rebuild_index, _from, state) do
    rebuild_ets_index()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:decay, state) do
    decay_relevance_scores()
    schedule_decay()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Save
  # ---------------------------------------------------------------------------

  defp do_save(content, opts) do
    category = Keyword.get(opts, :category) || auto_categorize(content)
    scope = opts |> Keyword.get(:scope, :global) |> to_string()
    source = opts |> Keyword.get(:source, :agent) |> to_string()
    tags = opts |> Keyword.get(:tags, []) |> Enum.join(",")
    session_id = Keyword.get(opts, :session_id)
    signal_weight = Keyword.get(opts, :signal_weight, 0.5)
    description = Keyword.get(opts, :description)

    keywords = extract_keywords(content)
    keywords_str = Enum.join(keywords, ",")
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    id = generate_id(content)

    entry = %{
      id: id,
      content: content,
      category: to_string(category),
      scope: scope,
      source: source,
      tags: tags,
      keywords: keywords_str,
      description: description,
      links: "",
      signal_weight: signal_weight,
      relevance: 1.0,
      access_count: 0,
      session_id: session_id,
      created_at: now,
      accessed_at: now,
      updated_at: now
    }

    similar = find_similar(entry, 5)
    action = consolidate(entry, similar)

    case action do
      :noop ->
        Logger.debug("[Memory.Store] NOOP — duplicate content, skipping")
        {:error, :duplicate}

      {:update, existing_id, merged_entry} ->
        persist_update(existing_id, merged_entry)

      {:add, new_entry} ->
        # A-MEM / Reweave: create bidirectional links to similar memories
        linked_ids = Enum.map(similar, fn {_score, s} -> s[:id] end) |> Enum.filter(&is_binary/1)
        new_entry = %{new_entry | links: Jason.encode!(linked_ids)}

        case persist_insert(new_entry) do
          {:ok, saved} ->
            # Backpass: update linked memories to also link back to this new entry
            reweave_links(saved[:id] || saved.id, linked_ids)
            {:ok, saved}

          error ->
            error
        end
    end
  end

  defp persist_insert(entry) do
    case %MemoryEntry{} |> MemoryEntry.changeset(entry) |> Repo.insert() do
      {:ok, saved} ->
        saved_map = struct_to_map(saved)
        index_entry(saved_map)
        cache_entry(saved_map)
        write_memory_md_async()
        Logger.debug("[Memory.Store] saved memory #{saved.id}")
        {:ok, saved_map}

      {:error, changeset} ->
        Logger.warning("[Memory.Store] insert failed: #{inspect(changeset.errors)}")
        {:error, changeset.errors}
    end
  end

  # Reweave: update existing memories to link back to the new entry.
  # This creates bidirectional links (A-MEM / Ars Contexta pattern).
  defp reweave_links(_new_id, []), do: :ok

  defp reweave_links(new_id, linked_ids) do
    Enum.each(linked_ids, fn existing_id ->
      try do
        case Repo.get(MemoryEntry, existing_id) do
          nil ->
            :ok

          existing ->
            current_links =
              case Jason.decode(existing.links || "[]") do
                {:ok, list} when is_list(list) -> list
                _ -> []
              end

            unless new_id in current_links do
              updated_links = Jason.encode!([new_id | current_links])

              existing
              |> MemoryEntry.changeset(%{
                links: updated_links,
                updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
              })
              |> Repo.update()

              # Update ETS cache too
              case :ets.lookup(@entries_table, existing_id) do
                [{^existing_id, cached}] ->
                  :ets.insert(
                    @entries_table,
                    {existing_id, Map.put(cached, :links, updated_links)}
                  )

                _ ->
                  :ok
              end
            end
        end
      rescue
        _ -> :ok
      end
    end)
  end

  defp persist_update(id, merged_entry) do
    case Repo.get(MemoryEntry, id) do
      nil ->
        persist_insert(merged_entry)

      existing ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updates = Map.merge(merged_entry, %{updated_at: now})

        case existing |> MemoryEntry.changeset(updates) |> Repo.update() do
          {:ok, updated} ->
            updated_map = struct_to_map(updated)
            reindex_entry(id, updated_map)
            cache_entry(updated_map)
            write_memory_md_async()
            Logger.debug("[Memory.Store] updated memory #{id}")
            {:ok, updated_map}

          {:error, changeset} ->
            Logger.warning("[Memory.Store] update failed: #{inspect(changeset.errors)}")
            {:error, changeset.errors}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Recall
  # ---------------------------------------------------------------------------

  defp do_recall(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    category = opts |> Keyword.get(:category) |> normalize_filter()
    scope = opts |> Keyword.get(:scope) |> normalize_filter()
    min_score = Keyword.get(opts, :min_score)

    query_keywords = extract_keywords(query)

    if Enum.empty?(query_keywords) do
      # Empty / stop-word-only query: NEVER run the "%%" LIKE fallback — it
      # table-scans and returns every row, which let context assembly dump the
      # whole memory DB into the prompt. Callers that want a listing must use
      # recent/1 explicitly.
      {:ok, []}
    else
      ets_ids = lookup_ets_index(query_keywords)

      entries =
        if Enum.empty?(ets_ids) do
          fallback_sqlite_search(query, category, scope, limit)
        else
          load_entries_by_ids(ets_ids, category, scope)
        end

      scored =
        entries
        |> Enum.map(fn e -> {score_relevance(e, query_keywords), e} end)
        |> maybe_filter_min_score(min_score)
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 1))

      bump_access_counts(scored)

      {:ok, scored}
    end
  end

  defp maybe_filter_min_score(scored, min_score) when is_number(min_score),
    do: Enum.filter(scored, fn {score, _entry} -> score >= min_score end)

  defp maybe_filter_min_score(scored, _), do: scored

  defp do_recent(limit) do
    entries =
      from(m in MemoryEntry, order_by: [desc: m.created_at], limit: ^limit)
      |> Repo.all()
      |> Enum.map(&struct_to_map/1)

    {:ok, entries}
  rescue
    e ->
      Logger.warning("[Memory.Store] recent error: #{Exception.message(e)}")
      {:ok, []}
  end

  defp lookup_ets_index(keywords) do
    try do
      keywords
      |> Enum.flat_map(fn kw ->
        case :ets.lookup(@index_table, kw) do
          [{^kw, ids}] -> ids
          [] -> []
        end
      end)
      |> Enum.uniq()
    rescue
      ArgumentError -> []
    end
  end

  defp load_entries_by_ids(ids, category, scope) do
    ids
    |> Enum.flat_map(fn id ->
      try do
        case :ets.lookup(@entries_table, id) do
          [{^id, entry}] -> [entry]
          [] -> load_from_sqlite_by_id(id)
        end
      rescue
        ArgumentError -> load_from_sqlite_by_id(id)
      end
    end)
    |> filter_by_category(category)
    |> filter_by_scope(scope)
  end

  defp load_from_sqlite_by_id(id) do
    case Repo.get(MemoryEntry, id) do
      nil -> []
      entry -> [struct_to_map(entry)]
    end
  rescue
    _ -> []
  end

  defp fallback_sqlite_search(query, category, scope, limit) do
    pattern = "%#{query}%"

    base_query =
      from(m in MemoryEntry,
        where: like(m.content, ^pattern) or like(m.keywords, ^pattern),
        order_by: [desc: m.relevance],
        limit: ^limit
      )

    base_query
    |> maybe_filter_category(category)
    |> maybe_filter_scope(scope)
    |> Repo.all()
    |> Enum.map(&struct_to_map/1)
  rescue
    e ->
      Logger.warning("[Memory.Store] SQLite fallback search error: #{Exception.message(e)}")
      []
  end

  defp bump_access_counts([]), do: :ok

  defp bump_access_counts(entries) do
    ids = Enum.map(entries, & &1.id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.update_all(
      from(m in MemoryEntry, where: m.id in ^ids),
      inc: [access_count: 1],
      set: [accessed_at: now]
    )

    Enum.each(entries, fn e ->
      updated = Map.update(e, :access_count, 1, &(&1 + 1))
      cache_entry(updated)
    end)
  rescue
    e ->
      Logger.warning("[Memory.Store] bump_access_counts error: #{Exception.message(e)}")
  end

  # ---------------------------------------------------------------------------
  # Get / Delete
  # ---------------------------------------------------------------------------

  defp do_get(id) do
    try do
      case :ets.lookup(@entries_table, id) do
        [{^id, entry}] ->
          {:ok, entry}

        [] ->
          case Repo.get(MemoryEntry, id) do
            nil -> {:error, :not_found}
            entry -> {:ok, struct_to_map(entry)}
          end
      end
    rescue
      ArgumentError ->
        case Repo.get(MemoryEntry, id) do
          nil -> {:error, :not_found}
          entry -> {:ok, struct_to_map(entry)}
        end
    end
  end

  defp do_delete(id) do
    case Repo.get(MemoryEntry, id) do
      nil ->
        {:error, :not_found}

      entry ->
        case Repo.delete(entry) do
          {:ok, _} ->
            remove_from_ets_index(id)
            remove_from_cache(id)
            write_memory_md_async()
            :ok

          {:error, changeset} ->
            {:error, changeset.errors}
        end
    end
  rescue
    e ->
      Logger.warning("[Memory.Store] delete error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  defp do_stats do
    result =
      from(m in MemoryEntry,
        select: %{
          total: count(m.id),
          avg_relevance: avg(m.relevance)
        }
      )
      |> Repo.one()

    by_category =
      from(m in MemoryEntry,
        group_by: m.category,
        select: {m.category, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    by_scope =
      from(m in MemoryEntry,
        group_by: m.scope,
        select: {m.scope, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    by_source =
      from(m in MemoryEntry,
        group_by: m.source,
        select: {m.source, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    {:ok,
     Map.merge(result || %{total: 0, avg_relevance: 0.0}, %{
       by_category: by_category,
       by_scope: by_scope,
       by_source: by_source
     })}
  rescue
    e ->
      Logger.warning("[Memory.Store] stats error: #{Exception.message(e)}")
      {:ok, %{total: 0, avg_relevance: 0.0, by_category: %{}, by_scope: %{}, by_source: %{}}}
  end

  # ---------------------------------------------------------------------------
  # MEMORY.md generation
  # ---------------------------------------------------------------------------

  defp write_memory_md do
    path = memory_md_path()

    entries =
      from(m in MemoryEntry, order_by: [desc: m.relevance, asc: m.category])
      |> Repo.all()

    content = render_memory_md(entries)

    case File.write(path, content) do
      :ok ->
        Logger.debug("[Memory.Store] wrote #{path}")
        :ok

      {:error, reason} ->
        Logger.warning("[Memory.Store] failed to write MEMORY.md: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Memory.Store] write_memory_md error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp write_memory_md_async do
    Task.Supervisor.start_child(
      OptimalSystemAgent.TaskSupervisor,
      fn -> write_memory_md() end
    )
  rescue
    _ -> :ok
  end

  defp render_memory_md(entries) do
    header = """
    # Memory Index

    Auto-generated from OSA memory store. Do not edit manually.
    Last updated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    """

    body =
      entries
      |> Enum.group_by(& &1.category)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {category, group} ->
        section_header = "## #{String.capitalize(category)}\n\n"

        rows =
          group
          |> Enum.map_join("\n", fn e ->
            tags = if e.tags && e.tags != "", do: " [#{e.tags}]", else: ""
            "- #{e.content}#{tags}"
          end)

        section_header <> rows <> "\n"
      end)

    header <> body
  end

  defp memory_md_path do
    osa_dir = Application.get_env(:optimal_system_agent, :config_dir, Path.expand("~/.osa"))
    Path.join(osa_dir, "MEMORY.md")
  end

  # ---------------------------------------------------------------------------
  # ETS table management
  # ---------------------------------------------------------------------------

  defp create_ets_tables do
    try do
      :ets.new(@index_table, [:named_table, :set, :public])
    rescue
      ArgumentError -> :already_exists
    end

    try do
      :ets.new(@entries_table, [:named_table, :set, :public])
    rescue
      ArgumentError -> :already_exists
    end
  end

  defp index_entry(entry) do
    keywords = parse_keywords(entry[:keywords] || entry["keywords"] || "")
    id = entry[:id] || entry["id"]

    Enum.each(keywords, fn kw ->
      try do
        existing =
          case :ets.lookup(@index_table, kw) do
            [{^kw, ids}] -> ids
            [] -> []
          end

        unless id in existing do
          :ets.insert(@index_table, {kw, [id | existing]})
        end
      rescue
        ArgumentError -> :ok
      end
    end)
  end

  defp reindex_entry(old_id, new_entry) do
    remove_from_ets_index(old_id)
    index_entry(new_entry)
  end

  defp remove_from_ets_index(id) do
    try do
      all_keys = :ets.tab2list(@index_table)

      Enum.each(all_keys, fn {kw, ids} ->
        updated = List.delete(ids, id)

        if updated == [] do
          :ets.delete(@index_table, kw)
        else
          :ets.insert(@index_table, {kw, updated})
        end
      end)
    rescue
      ArgumentError -> :ok
    end
  end

  defp cache_entry(entry) do
    id = entry[:id] || entry["id"]

    try do
      :ets.insert(@entries_table, {id, entry})
    rescue
      ArgumentError -> :ok
    end
  end

  defp remove_from_cache(id) do
    try do
      :ets.delete(@entries_table, id)
    rescue
      ArgumentError -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # SQLite bootstrap
  # ---------------------------------------------------------------------------

  defp load_from_sqlite do
    try do
      entries = Repo.all(MemoryEntry)
      Logger.info("[Memory.Store] loaded #{length(entries)} memories from SQLite")

      Enum.each(entries, fn entry ->
        entry_map = struct_to_map(entry)
        index_entry(entry_map)
        cache_entry(entry_map)
      end)
    rescue
      e ->
        Logger.warning("[Memory.Store] failed to load from SQLite: #{Exception.message(e)}")
    end
  end

  defp rebuild_ets_index do
    try do
      :ets.delete_all_objects(@index_table)
      :ets.delete_all_objects(@entries_table)
    rescue
      ArgumentError -> :ok
    end

    load_from_sqlite()
  end

  # ---------------------------------------------------------------------------
  # Keyword extraction
  # ---------------------------------------------------------------------------

  defp extract_keywords(content) when is_binary(content) do
    content
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp extract_keywords(_), do: []

  defp parse_keywords(""), do: []
  defp parse_keywords(nil), do: []

  defp parse_keywords(keywords_str) when is_binary(keywords_str) do
    keywords_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ---------------------------------------------------------------------------
  # Auto-categorisation
  # ---------------------------------------------------------------------------

  defp auto_categorize(content) when is_binary(content) do
    lower = String.downcase(content)
    do_auto_categorize(lower)
  end

  defp auto_categorize(_), do: "context"

  defp do_auto_categorize(lower) do
    cond do
      matches_decision?(lower) -> "decision"
      matches_pattern?(lower) -> "pattern"
      matches_lesson?(lower) -> "lesson"
      matches_preference?(lower) -> "preference"
      matches_project?(lower) -> "project"
      true -> "context"
    end
  end

  defp matches_decision?(text) do
    Regex.match?(~r/\b(prefer|always|never|decided|decision|rule|policy|must|should)\b/, text)
  end

  defp matches_pattern?(text) do
    Regex.match?(
      ~r/\b(recurring|common|typical|pattern|usually|often|frequently|tend to)\b/,
      text
    )
  end

  defp matches_lesson?(text) do
    Regex.match?(
      ~r/\b(mistake|bug|fix|fixed|learned|lesson|error|broke|broke|failed|issue)\b/,
      text
    )
  end

  defp matches_preference?(text) do
    Regex.match?(~r/\b(like|want|prefer|dislike|love|hate|enjoy|don.t like)\b/, text)
  end

  defp matches_project?(text) do
    Regex.match?(~r/\b(project|repo|repository|codebase|module|library|package|app)\b/, text)
  end

  # ---------------------------------------------------------------------------
  # Similarity and consolidation (Mem0-style)
  # ---------------------------------------------------------------------------

  defp find_similar(entry, limit) do
    entry_keywords = parse_keywords(entry.keywords)

    try do
      candidate_ids = lookup_ets_index(entry_keywords)

      candidate_ids
      |> Enum.reject(&(&1 == entry.id))
      |> Enum.flat_map(fn id ->
        case :ets.lookup(@entries_table, id) do
          [{^id, cached}] -> [cached]
          [] -> []
        end
      end)
      |> Enum.map(fn candidate ->
        overlap =
          keyword_overlap_score(entry_keywords, parse_keywords(candidate[:keywords] || ""))

        {overlap, candidate}
      end)
      |> Enum.filter(fn {score, _} -> score >= @similarity_threshold end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(limit)
    rescue
      ArgumentError -> []
    end
  end

  defp consolidate(new_entry, []) do
    {:add, new_entry}
  end

  defp consolidate(_new_entry, [{score, _existing} | _]) when score >= @duplicate_threshold do
    # Near-identical content — treat as a duplicate and skip the write.
    :noop
  end

  defp consolidate(new_entry, [{score, existing} | _]) when score >= @merge_threshold do
    # High overlap (but not a duplicate) — the new fact refines the existing one,
    # so merge. Growth is capped: if the target row is already large, or the merge
    # would exceed the size ceiling, we DON'T garble it — we fall back to storing
    # the new fact as its own (linked) entry.
    case merge_entry(existing, new_entry) do
      {:ok, merged} -> {:update, existing[:id], merged}
      :too_large -> {:add, new_entry}
    end
  end

  defp consolidate(new_entry, _similar) do
    # Candidate-but-not-merge band (@similarity_threshold <= score < @merge_threshold):
    # the entries merely share keywords, they are NOT the same fact. Store the new
    # entry separately. do_save/2 still records A-MEM links to these candidates, so
    # the association is preserved without collapsing two memories into one.
    {:add, new_entry}
  end

  # Merge the new entry's content into an existing entry, bounding growth so a
  # single row can't accumulate content forever. Returns {:ok, merged} or
  # :too_large when the merge should be declined in favour of a separate insert.
  defp merge_entry(existing, new_entry) do
    existing_content = existing[:content] || ""

    if String.length(existing_content) > @max_merge_content_chars do
      :too_large
    else
      merged_content = build_merged_content(existing_content, new_entry.content)

      if String.length(merged_content) > @max_merge_content_chars do
        :too_large
      else
        merged_keywords =
          (parse_keywords(existing[:keywords] || "") ++ parse_keywords(new_entry.keywords))
          |> Enum.uniq()
          |> Enum.join(",")

        merged =
          existing
          |> Map.merge(%{
            content: merged_content,
            keywords: merged_keywords,
            signal_weight: max(existing[:signal_weight] || 0.5, new_entry.signal_weight),
            relevance: 1.0
          })

        {:ok, merged}
      end
    end
  end

  # Append the new content as an "Updated:" segment, keeping only the base content
  # plus the most recent @max_updated_segments refinements. Duplicate segments are
  # dropped so re-saving the same near-duplicate is idempotent.
  defp build_merged_content(existing_content, new_content) do
    [base | prior] = String.split(existing_content, @updated_delim)

    segments =
      (prior ++ [new_content])
      |> Enum.uniq()
      |> Enum.take(-@max_updated_segments)

    Enum.join([base | segments], @updated_delim)
  end

  defp keyword_overlap_score([], _), do: 0.0
  defp keyword_overlap_score(_, []), do: 0.0

  defp keyword_overlap_score(kws_a, kws_b) do
    set_a = MapSet.new(kws_a)
    set_b = MapSet.new(kws_b)
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()
    if union == 0, do: 0.0, else: intersection / union
  end

  # ---------------------------------------------------------------------------
  # Relevance scoring
  # ---------------------------------------------------------------------------

  defp score_relevance(entry, query_keywords) do
    base_match = keyword_overlap_score(parse_keywords(entry[:keywords] || ""), query_keywords)
    signal_weight = entry[:signal_weight] || 0.5
    recency = compute_recency(entry[:created_at] || entry["created_at"])

    base_match * 0.30 + signal_weight * 0.50 + recency * 0.20
  end

  defp compute_recency(nil), do: 0.5

  defp compute_recency(created_at) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, dt, _} ->
        age_days = DateTime.diff(DateTime.utc_now(), dt, :second) / 86_400
        max(0.0, 1.0 - age_days / 30.0)

      _ ->
        0.5
    end
  end

  defp compute_recency(_), do: 0.5

  # ---------------------------------------------------------------------------
  # Relevance decay
  # ---------------------------------------------------------------------------

  defp decay_relevance_scores do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Decay entries not accessed in 7+ days by 5%
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-7 * 24 * 3600, :second)
      |> DateTime.to_iso8601()

    Repo.update_all(
      from(m in MemoryEntry,
        where: m.accessed_at < ^cutoff and m.relevance > 0.1
      ),
      set: [updated_at: now],
      inc: []
    )

    # Raw SQL-style: multiply relevance by 0.95 for stale entries
    # Ecto doesn't support fragment updates directly with update_all arithmetic,
    # so we pull affected IDs and update in bulk.
    stale_ids =
      from(m in MemoryEntry,
        where: m.accessed_at < ^cutoff and m.relevance > 0.1,
        select: m.id
      )
      |> Repo.all()

    Enum.each(stale_ids, fn id ->
      Repo.update_all(
        from(m in MemoryEntry, where: m.id == ^id),
        set: [relevance: decay_value(id)]
      )
    end)

    # Evict stale entries from ETS cache so next recall reloads fresh
    Enum.each(stale_ids, fn id ->
      remove_from_cache(id)
    end)

    if length(stale_ids) > 0 do
      Logger.debug("[Memory.Store] decayed #{length(stale_ids)} stale memories")
    end
  rescue
    e ->
      Logger.warning("[Memory.Store] decay error: #{Exception.message(e)}")
  end

  defp decay_value(id) do
    case Repo.get(MemoryEntry, id) do
      nil -> 0.1
      entry -> max(0.1, (entry.relevance || 1.0) * 0.95)
    end
  rescue
    _ -> 0.1
  end

  defp schedule_decay do
    Process.send_after(self(), :decay, @decay_interval_ms)
  end

  # ---------------------------------------------------------------------------
  # ID generation
  # ---------------------------------------------------------------------------

  defp generate_id(content) do
    timestamp = System.system_time(:nanosecond) |> to_string()

    :crypto.hash(:sha256, content <> timestamp)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ---------------------------------------------------------------------------
  # Query helpers
  # ---------------------------------------------------------------------------

  defp normalize_filter(nil), do: nil
  defp normalize_filter(val) when is_atom(val), do: to_string(val)
  defp normalize_filter(val) when is_binary(val), do: val

  defp filter_by_category(entries, nil), do: entries

  defp filter_by_category(entries, cat),
    do: Enum.filter(entries, &((&1[:category] || &1["category"]) == cat))

  defp filter_by_scope(entries, nil), do: entries

  defp filter_by_scope(entries, scope),
    do: Enum.filter(entries, &((&1[:scope] || &1["scope"]) == scope))

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, cat), do: from(m in query, where: m.category == ^cat)

  defp maybe_filter_scope(query, nil), do: query
  defp maybe_filter_scope(query, scope), do: from(m in query, where: m.scope == ^scope)

  # ---------------------------------------------------------------------------
  # Struct → plain map conversion
  # ---------------------------------------------------------------------------

  defp struct_to_map(%MemoryEntry{} = entry) do
    %{
      id: entry.id,
      content: entry.content,
      category: entry.category,
      scope: entry.scope,
      source: entry.source,
      tags: entry.tags,
      keywords: entry.keywords,
      description: entry.description,
      links: entry.links,
      signal_weight: entry.signal_weight,
      relevance: entry.relevance,
      access_count: entry.access_count,
      session_id: entry.session_id,
      created_at: entry.created_at,
      accessed_at: entry.accessed_at,
      updated_at: entry.updated_at
    }
  end
end
