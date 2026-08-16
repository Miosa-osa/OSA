defmodule OptimalSystemAgent.Memory do
  @moduledoc """
  Unified memory service — save, recall, search, learn.

  This is the public API facade for all memory operations. It is NOT a GenServer
  itself; it delegates every operation to Memory.Store via synchronous calls.

  ## Categories (SICA taxonomy)

    - `:decision`   — explicit preferences, rules, choices the user stated
    - `:pattern`    — recurring behaviours, common approaches, typical flows
    - `:lesson`     — mistakes made, bugs fixed, things learned the hard way
    - `:preference` — likes/wants/dislikes expressed by the user
    - `:project`    — project-specific context, repo facts, codebase notes
    - `:context`    — general situational facts that don't fit other categories

  ## Scopes

    - `:global`    — persists across all sessions (default)
    - `:workspace` — scoped to a workspace directory
    - `:session`   — discarded after the session ends

  ## Usage

      # Save with auto-categorisation
      Memory.save("User always prefers tabs over spaces")

      # Save with explicit opts
      Memory.save("Prefer Ecto over raw SQL", category: :decision, tags: ["elixir", "db"])

      # Recall by keyword
      {:ok, entries} = Memory.recall("Ecto SQL")

      # Scoped recall
      {:ok, entries} = Memory.recall("tabs", category: :preference, limit: 5)
  """

  require Logger

  alias OptimalSystemAgent.Memory.Store
  alias OptimalSystemAgent.Memory.{Scoring, Search, MMR, QueryExpansion}

  # ---------------------------------------------------------------------------
  # Call bounds
  # ---------------------------------------------------------------------------
  #
  # Every operation below used `GenServer.call(Store, _, :infinity)`. `Store`
  # serializes ALL of them in one `handle_call` loop, and the READ paths sit on
  # the user's turn: `Agent.Context` calls `recall_hybrid/2` during context
  # assembly on essentially every turn, and the memory_recall / memory_save /
  # session_search / semantic_search tools call in from tool execution.
  #
  # With `:infinity`, one slow neighbour on that same serialized process — a
  # `:rebuild_index` over a large SQLite store, a `:regenerate_md` writing
  # ~/.osa/MEMORY.md, a `:consolidate` cycle — head-of-line blocks a live turn
  # FOREVER. In a multi-hour session those maintenance operations are exactly
  # what runs while the user is mid-task. This is the "hangs and never comes
  # back" shape, not a slow-query shape.
  #
  # Bounds are generous (a healthy call is single-digit ms) and a breach is
  # DEGRADED, never fatal: `bounded_call/3` catches the exit and returns the
  # supplied fallback, so a wedged memory store costs the turn its memory
  # context instead of the whole turn. Tunable via `:memory_call_timeout_ms` /
  # `:memory_maintenance_timeout_ms`.
  @default_read_timeout_ms 5_000
  @default_maintenance_timeout_ms 30_000

  defp read_timeout,
    do:
      Application.get_env(
        :optimal_system_agent,
        :memory_call_timeout_ms,
        @default_read_timeout_ms
      )

  defp maintenance_timeout,
    do:
      Application.get_env(
        :optimal_system_agent,
        :memory_maintenance_timeout_ms,
        @default_maintenance_timeout_ms
      )

  # Bounded, non-fatal GenServer.call. On timeout//noproc the caller gets
  # `fallback` and a warning is logged — the turn continues without memory
  # rather than blocking on it.
  defp bounded_call(request, timeout, fallback) do
    GenServer.call(Store, request, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning(
        "[memory] Store call timed out after #{timeout}ms (#{inspect(elem_or(request))}) — " <>
          "continuing without memory for this call"
      )

      fallback

    :exit, reason ->
      Logger.warning(
        "[memory] Store unavailable (#{inspect(reason)}) — returning #{inspect(fallback)}"
      )

      fallback
  end

  defp elem_or(request) when is_tuple(request), do: elem(request, 0)
  defp elem_or(request), do: request

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Save a memory entry.

  Options:
    - `:category`      — one of: decision | pattern | lesson | preference | project | context
    - `:scope`         — one of: global | workspace | session (default: global)
    - `:tags`          — list of string tags e.g. ["elixir", "testing"]
    - `:source`        — one of: user | agent | system | sica (default: agent)
    - `:session_id`    — session that originated this memory
    - `:signal_weight` — float 0.0–1.0, importance weight (default: 0.5)
    - `:description`   — optional short description / title

  If no `:category` is given, one is automatically inferred from the content.

  Duplicate detection runs before insertion. Depending on similarity to
  existing entries the action will be one of: ADD | UPDATE | NOOP.

  Returns `{:ok, entry}` on success or `{:error, reason}` on failure.
  """
  @spec save(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def save(content, opts \\ []) when is_binary(content) do
    bounded_call({:save, content, opts}, maintenance_timeout(), {:error, :memory_timeout})
  end

  @doc """
  Search memories by keyword query.

  Searches the in-memory ETS keyword index first, then falls back to SQLite
  FTS5 for entries not yet indexed. Results are ranked by a weighted
  relevance score: 30% base keyword match + 50% contextual signal weight
  + 20% recency. Access counts are bumped on every successful recall.

  Options:
    - `:category`  — filter by category atom or string
    - `:scope`     — filter by scope atom or string
    - `:limit`     — maximum entries to return (default: 10)
    - `:min_score` — drop entries whose relevance score is below this threshold

  An empty or stop-word-only query returns `{:ok, []}` — it never table-scans.
  Use `recent/1` for an explicit listing.

  Returns `{:ok, [entry, ...]}`.
  """
  @spec recall(String.t(), keyword()) :: {:ok, [map()]}
  def recall(query, opts \\ []) when is_binary(query) do
    bounded_call({:recall, query, opts}, read_timeout(), {:ok, []})
  end

  @doc """
  Retrieve a single memory entry by its ID.

  Returns `{:ok, entry}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    bounded_call({:get, id}, read_timeout(), {:error, :not_found})
  end

  @doc """
  Return the most recent memory entries, newest first.

  Returns `{:ok, [entry, ...]}`.
  """
  @spec recent(pos_integer()) :: {:ok, [map()]}
  def recent(limit \\ 10) when is_integer(limit) and limit > 0 do
    bounded_call({:recent, limit}, read_timeout(), {:ok, []})
  end

  @doc """
  Delete a memory entry by ID.

  Removes from both SQLite and the ETS index.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) when is_binary(id) do
    bounded_call({:delete, id}, maintenance_timeout(), {:error, :memory_timeout})
  end

  @doc """
  Search past session messages (conversation history).

  Delegates to the SQLite message store via a LIKE query. Useful for
  recalling what was discussed in previous sessions.

  Options:
    - `:limit` — maximum messages to return (default: 20)

  Returns `{:ok, [message, ...]}`.
  """
  @spec search_sessions(String.t(), keyword()) :: {:ok, [map()]}
  def search_sessions(query, opts \\ []) when is_binary(query) do
    bounded_call({:search_sessions, query, opts}, read_timeout(), {:ok, []})
  end

  @doc """
  Return aggregate memory statistics.

  Returns a map with keys: total, by_category, by_scope, by_source, avg_relevance.
  """
  @spec stats() :: {:ok, map()}
  def stats do
    bounded_call(
      :stats,
      read_timeout(),
      {:ok, %{total: 0, by_category: %{}, by_scope: %{}, by_source: %{}, avg_relevance: 0.0}}
    )
  end

  @doc """
  Rebuild the in-memory ETS index from SQLite.

  Use this to recover from an ETS table being dropped (e.g. after a node crash
  that left the GenServer restarted but the application ETS tables gone).

  Returns `:ok`.
  """
  @spec rebuild_index() :: :ok
  def rebuild_index do
    bounded_call(:rebuild_index, maintenance_timeout(), :ok)
  end

  @doc """
  Regenerate `~/.osa/MEMORY.md` from all current SQLite memory entries.

  This is called automatically on save but can be triggered manually to
  repair a missing or stale file.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec regenerate_md() :: :ok | {:error, term()}
  def regenerate_md do
    bounded_call(:regenerate_md, maintenance_timeout(), {:error, :memory_timeout})
  end

  # ---------------------------------------------------------------------------
  # Hybrid RAG recall (P1: keyword + vector KNN + MMR diversity + query
  # expansion — see Memory.Search / Memory.MMR / Memory.QueryExpansion)
  # ---------------------------------------------------------------------------

  @doc """
  Hybrid memory recall — the recall-quality upgrade over `recall/2`.

  Fuses four signals into one score per candidate, then diversity-re-ranks:

    1. **Query expansion** (`Memory.QueryExpansion`) — the query's keywords
       are widened with a small synonym table + light stemming before
       lexical scoring, so near-synonyms of a stored memory still match.
    2. **Lexical / recency / category score** (`Memory.Scoring.score/3`) —
       the existing category-weight + Jaccard keyword-overlap + recency
       blend (OSA has no FTS5 BM25 index over the `memories` table today;
       this is the lexical component in its place).
    3. **Vector KNN** (`Memory.Search`) — cosine similarity between the
       query embedding and each candidate's embedding, catching
       semantically-related but lexically-different memories that (2) alone
       would miss entirely. Skipped automatically (weight 0) if no
       embedding provider is configured/reachable — see `Search.available?/0`
       and `Search.embed/1`.
    4. **MMR diversity re-rank** (`Memory.MMR`) — greedy Maximal Marginal
       Relevance selection over the fused-score candidates so the returned
       set isn't dominated by three near-duplicate phrasings of the same
       fact.

  Candidates are gathered from two pools and unioned by id: the existing
  keyword/ETS-index pool (`Store`'s recall, run against the *expanded*
  query) and a recency-bounded broad pool (`recent/1`) that vector-KNN scores
  even though it wasn't keyword-matched — this second pool is what lets
  hybrid recall surface entries keyword search would never have looked at.

  ## Recency is not a path in

  The broad pool is gathered ONLY when there is a query embedding to score it
  against (it exists to feed vector KNN, and its members are by construction
  the ones lexical recall did not match), and a candidate that arrived solely
  through it must show evidence of being related — non-zero keyword overlap,
  or cosine similarity at or above `:semantic_floor` — before it is eligible.

  Without that gate a memory reached the prompt on category weight and recency
  alone: `Scoring.score/3` is `base*0.30 + context*0.50 + recency*0.20`, so a
  freshly-saved `:decision` entry scores `0.50` against a query it shares not
  one word with, clearing the `0.35` floor `Agent.Context` applies. MEASURED on
  a real 60-entry store at production settings, 75% of injected entries shared
  zero keywords with the request. Keyword-pool candidates are exempt from the
  gate, so this never returns less than `recall/2` would.

  Options:
    - `:limit`       — max entries returned (default: 10)
    - `:category`    — filter by category atom or string
    - `:scope`       — filter by scope atom or string
    - `:min_score`   — drop candidates whose fused score is below this
                       threshold (applied before MMR)
    - `:lambda`       — MMR relevance/diversity trade-off, `0.0..1.0`
                       (default `0.7`; forwarded to `Memory.MMR.rerank/2`)
    - `:vector_weight` — blend weight for the vector-KNN component when
                       embeddings ARE available (default `0.4`; the lexical
                       component gets the remaining `1.0 - vector_weight`).
                       Automatically forced to `0.0` when embeddings are
                       unavailable, so the fused score degrades EXACTLY to
                       the existing lexical/recency/category score.
    - `:candidate_pool` — how many broad-pool candidates (via `recent/1`) to
                       consider for vector KNN (default: 100). Not gathered at
                       all when there is no query embedding.
    - `:semantic_floor` — cosine similarity a broad-pool-only candidate must
                       reach to count as related (default `0.55`, override via
                       `:memory_semantic_floor`). See "Recency is not a path
                       in" above.

  Returns `{:ok, [entry, ...]}`, best first — same shape as `recall/2`, so it
  is a drop-in replacement at call sites. On ANY internal error (embedding
  provider crash, unexpected data shape, etc.) this NEVER raises and NEVER
  returns fewer guarantees than `recall/2` — it falls back to plain
  `recall/2` with the same opts.
  """
  @spec recall_hybrid(String.t(), keyword()) :: {:ok, [map()]}
  def recall_hybrid(query, opts \\ []) when is_binary(query) do
    do_recall_hybrid(query, opts)
  rescue
    e ->
      Logger.warning(
        "[Memory] recall_hybrid error, falling back to recall/2: #{Exception.message(e)}"
      )

      recall(query, opts)
  catch
    :exit, reason ->
      Logger.warning("[Memory] recall_hybrid exit, falling back to recall/2: #{inspect(reason)}")
      recall(query, opts)
  end

  defp do_recall_hybrid(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score)
    lambda = Keyword.get(opts, :lambda, 0.7)
    vector_weight_opt = Keyword.get(opts, :vector_weight, 0.4)
    candidate_pool = Keyword.get(opts, :candidate_pool, 100)
    category = Keyword.get(opts, :category)
    scope = Keyword.get(opts, :scope)

    query_keywords = Scoring.extract_keywords(query)

    if query_keywords == [] do
      # Mirror recall/2's empty/stop-word-only guard — never table-scan.
      {:ok, []}
    else
      expanded_keywords = QueryExpansion.expand_keywords(query_keywords)
      expanded_query = QueryExpansion.expand_query(query)

      keyword_pool_limit = max(limit * 4, 40)

      {:ok, keyword_candidates} =
        recall(expanded_query,
          limit: keyword_pool_limit,
          category: category,
          scope: scope
        )

      # The query embedding is resolved BEFORE the broad pool is gathered,
      # because it decides whether gathering one means anything. See
      # `broad_pool/3`.
      query_vector = maybe_embed_query(query, opts)

      broad_candidates =
        query_vector
        |> broad_pool(candidate_pool, category: category, scope: scope)

      keyword_ids = MapSet.new(keyword_candidates, &entry_id/1)
      floor = semantic_floor(opts)

      union_candidates =
        (keyword_candidates ++ broad_candidates)
        |> Enum.uniq_by(&entry_id/1)

      {vector_scores, embeddings} = knn_scores(query_vector, union_candidates)

      vector_weight = if query_vector, do: vector_weight_opt, else: 0.0
      lexical_weight = 1.0 - vector_weight

      scored =
        union_candidates
        |> Enum.map(fn entry ->
          lexical = Scoring.score(entry, expanded_keywords)
          vector_sim = Map.get(vector_scores, entry_id(entry), 0.0)
          fused = lexical * lexical_weight + vector_sim * vector_weight
          {fused, entry}
        end)
        |> Enum.filter(fn {_fused, entry} ->
          related?(entry, expanded_keywords, vector_scores, keyword_ids, floor)
        end)
        |> maybe_filter_min_score(min_score)
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.take(max(limit * 3, limit))

      diversified =
        scored
        |> MMR.rerank(limit: limit, lambda: lambda, embeddings: embeddings)

      {:ok, diversified}
    end
  end

  # Embed the query under a DEADLINE.
  #
  # `Search.embed/1` is an HTTP round-trip to the embedding provider with a
  # 5-second receive timeout. That is a fine budget for the `memory_recall` /
  # `semantic_search` tools, where the user asked for a search and the answer is
  # the point. It is the wrong budget for `Agent.Context`, which calls this
  # while ASSEMBLING THE PROMPT, before the request is sent: a slow or wedged
  # embedder there does not degrade recall quality, it stalls the turn — and the
  # caller cannot tell the difference between "thinking" and "blocked on a
  # sidecar".
  #
  # The vector score is strictly optional: `{:error, _}` falls through to the
  # pure-lexical path a few lines below, which is what already happens when no
  # embedder is configured at all. So the prompt path passes a tight
  # `:embed_deadline_ms` and takes the lexical answer if the embedder does not
  # make it. Without the option the behaviour is exactly as before.
  defp embed_within_deadline(query, opts) do
    case Keyword.get(opts, :embed_deadline_ms) do
      ms when is_integer(ms) and ms > 0 ->
        task = Task.async(fn -> Search.embed(query) end)

        case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            result

          _ ->
            Logger.debug("[Memory] embed exceeded #{ms}ms deadline — lexical recall only")
            {:error, :embed_deadline}
        end

      _ ->
        Search.embed(query)
    end
  end

  # Attempts to embed the query. `nil` on any failure (no provider,
  # unreachable, bad response, past the deadline) — pure lexical fallback,
  # never raises.
  defp maybe_embed_query(query, opts) do
    if Search.available?() do
      case embed_within_deadline(query, opts) do
        {:ok, query_vector} -> query_vector
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  # KNN-score the candidate pool against the query vector. Returns
  # `{%{id => similarity}, %{id => vector}}`, or empty maps when there is no
  # query vector to score against.
  defp knn_scores(nil, _candidates), do: {%{}, %{}}

  defp knn_scores(query_vector, candidates) do
    {scored, embeddings} = Search.knn(query_vector, candidates)
    {Map.new(scored, fn {sim, entry} -> {entry_id(entry), sim} end), embeddings}
  end

  # The recency-bounded broad pool.
  #
  # This pool exists for ONE reason, stated in `recall_hybrid/2`'s docstring:
  # to give vector KNN entries to look at that keyword search never retrieved.
  # Its members are, by construction, the ones lexical recall did NOT match —
  # so with no query vector to score them against, every one of them is noise
  # that lexical scoring cannot distinguish from signal. Gathering it anyway
  # was the defect: `Scoring.score/3` mixes category weight and recency in, and
  # those two alone reach 0.50 against a query the entry shares nothing with,
  # clearing the 0.35 floor `Agent.Context` applies. The result was that the
  # "## Long-term Memory" block was in practice the most RECENTLY SAVED
  # memories rather than the relevant ones.
  #
  # So: no query vector, no broad pool. Recall degrades to exactly what
  # `recall/2` returns, which is what the docstring already promises is the
  # floor for this function. It also saves a `recent/1` round-trip and scoring
  # pass on every turn where the embedder is absent, misconfigured, or slower
  # than the prompt-assembly deadline.
  defp broad_pool(nil, _candidate_pool, _filters), do: []

  defp broad_pool(_query_vector, candidate_pool, filters) do
    {:ok, entries} = recent(candidate_pool)

    entries
    |> filter_by(:category, filters[:category])
    |> filter_by(:scope, filters[:scope])
  end

  # Default cosine floor a BROAD-POOL-ONLY candidate must clear to count as
  # semantically related.
  #
  # MEASURED against the operator's real 60-entry store with the live
  # `nomic-embed-text` embedder: for queries the store genuinely answers, the
  # true matches sit at cosine 0.55–0.84, while for queries it has nothing on
  # ("tailwind dark mode convention", "goroutine leak detection", "pizza
  # toppings") the single BEST candidate peaked at 0.43–0.50. This embedder has
  # a high similarity floor — nothing scores near 0 — so a threshold is
  # unavoidable, and 0.55 sits in the measured gap.
  #
  # Getting it wrong is bounded and one-directional: the lexical-evidence limb
  # of `related?/5` is unconditional and every keyword-pool candidate bypasses
  # this check entirely, so an ill-fitting floor costs the SEMANTIC bonus and
  # degrades to `recall/2`'s keyword answer. It cannot drop a lexically
  # relevant memory. Tunable for a different embedder via
  # `:memory_semantic_floor`.
  @default_semantic_floor 0.55

  defp semantic_floor(opts) do
    Keyword.get(opts, :semantic_floor) ||
      Application.get_env(
        :optimal_system_agent,
        :memory_semantic_floor,
        @default_semantic_floor
      )
  end

  # Does this candidate have any evidence of being RELATED to the request, as
  # opposed to merely recent and well-categorised?
  #
  # Keyword-pool candidates are exempt: they were retrieved by matching a query
  # keyword in the first place, and exempting them keeps `recall_hybrid/2`'s
  # standing guarantee that it never returns fewer results than `recall/2`
  # would. Only broad-pool-only candidates — the ones that arrived on recency —
  # have to show their work, via either limb:
  #
  #   * lexical  — non-zero keyword overlap with the expanded query
  #   * semantic — cosine similarity at or above `semantic_floor/1`
  #
  # Recency still matters: it is 20% of `Scoring.score/3` and continues to rank
  # related entries against each other, and a fact saved seconds ago is still
  # reachable the moment it is plausibly on topic. What it can no longer do is
  # buy a seat in the prompt on its own.
  defp related?(entry, expanded_keywords, vector_scores, keyword_ids, floor) do
    id = entry_id(entry)

    MapSet.member?(keyword_ids, id) or
      Scoring.context_relevance(entry, expanded_keywords) > 0.0 or
      Map.get(vector_scores, id, 0.0) >= floor
  end

  defp maybe_filter_min_score(scored, min_score) when is_number(min_score),
    do: Enum.filter(scored, fn {score, _entry} -> score >= min_score end)

  defp maybe_filter_min_score(scored, _), do: scored

  defp filter_by(entries, _key, nil), do: entries

  defp filter_by(entries, key, value) do
    target = to_string(value)
    Enum.filter(entries, &(to_string(&1[key] || &1[to_string(key)]) == target))
  end

  defp entry_id(entry), do: entry[:id] || entry["id"]
end
