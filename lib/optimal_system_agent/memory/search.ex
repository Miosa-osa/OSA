defmodule OptimalSystemAgent.Memory.Search do
  @moduledoc """
  Vector embedding + cosine-KNN half of hybrid memory recall.

  Reference: grok `xai-grok-memory/src/search.rs` ("Hybrid search combining
  FTS5 BM25 + sqlite-vec KNN + temporal decay + source weighting + MMR").

  ## Embedding provider

  OSA has no dedicated embedding-provider abstraction today (checked: no
  `/embeddings` endpoint wiring anywhere under `lib/optimal_system_agent/providers/`).
  Rather than invent a whole new provider subsystem, this module reuses the
  already-configured **local Ollama** connection (`:ollama_url`, the same
  config key `Providers.Ollama` uses) and calls Ollama's native
  `POST /api/embeddings` endpoint. This requires an embedding-capable model
  to be pulled locally (e.g. `nomic-embed-text`) — configurable via
  `:optimal_system_agent, :embedding_model`.

  This is intentionally the ONLY network dependency added by hybrid recall,
  and every call site degrades to `{:error, _}` on any failure (model not
  pulled, Ollama not running, timeout, provider disabled) — recall NEVER
  hard-fails; callers fall back to keyword-only scoring.

  ## Vector storage — persisted SQLite (BLOB/TEXT column), warmed into ETS

  Vectors are now DURABLY persisted, one row per memory `id`, in a dedicated
  `memory_vectors` table (`priv/repo/migrations/20260719000001_create_memory_vectors.exs`,
  schema `Memory.VectorEntry`) in the SAME SQLite database the memory store
  uses (`OptimalSystemAgent.Store.Repo`). The in-memory ETS table
  (`:osa_memory_vectors`) is kept as a **warm read cache** in front of it —
  first access after boot lazily loads (or is populated by writes to) SQLite;
  subsequent lookups in the same run stay ETS-speed.

  ### Why a plain column instead of `sqlite-vec`

  `sqlite-vec` is a native SQLite loadable extension. This project's SQLite
  access goes through `ecto_sqlite3` / `exqlite`
  (`OptimalSystemAgent.Store.Repo`, `adapter: Ecto.Adapters.SQLite3`), and
  `exqlite` does not expose a way to `load_extension` an arbitrary native
  extension from application code — that would mean patching `exqlite`'s NIF
  build itself, well outside this change's scope. Instead, each embedding is
  stored as a JSON-encoded float array in a `:text` column
  (`Memory.VectorEntry.embedding`) and cosine similarity/KNN stays exactly
  what it already was: an in-Elixir scan (`cosine_similarity/2`, `knn/2`,
  unchanged). OSA's memory table is small (hundreds—low thousands of rows),
  so an O(n) in-memory cosine scan over a per-run-warmed ETS table is not a
  bottleneck.

  ### Invalidation

  Every persisted row carries `content_hash` (`:erlang.phash2/1` of the
  embedded text — the SAME hash the ETS cache always used). On lookup, a
  mismatched hash (content changed since it was embedded) is treated as a
  cache miss: the entry is re-embedded and the persisted row is upserted.
  `forget/1` deletes both the ETS entry and the persisted row (e.g. after a
  memory entry is deleted or its content is merged into another row).

  ### Cache bound (LRU)

  The ETS half is a **cache**, and it is capped like one: `@default_cache_max`
  entries (override with `config :optimal_system_agent, :memory_vector_cache_max`),
  evicted least-recently-used first. Nothing else prunes it — in particular
  `Memory.Consolidator` LOOKS like it covers this and does not: it is a plain
  module (no GenServer, no timer), it is called only from
  `Memory.Learning.run_consolidation/2`, and everything it prunes is *patterns*
  in the `Store.Pattern` SQLite table via `Repo.delete_all`. It never touches
  `:osa_memory_vectors` or any ETS table at all. A prune that appears to cover
  something it doesn't is worse than none, so the cap here is the only thing
  bounding this table, and `forget/1` (explicit entry deletion) remains the only
  other way a row leaves it.

  Eviction is safe *because* of the persistence layer above: an evicted vector
  is still in SQLite, so a subsequent lookup is one disk read, not a re-embed.
  This is also the heaviest per-row growth in the codebase — a row holds a full
  float list (~768 floats for `nomic-embed-text`, on the order of 25 KB of BEAM
  term), so at the default cap the table tops out around 50 MB rather than
  growing for the life of the process.

  ### Degradation

  Every SQLite read/write here is wrapped and rescued — a DB error never
  prevents recall from working, it just falls back to a live (or failed)
  embed exactly as before this persistence layer existed. When no embedding
  provider is configured (`available?/0` false), nothing is embedded or
  persisted at all and callers degrade to keyword-only scoring, unchanged.
  """

  require Logger

  alias OptimalSystemAgent.Store.Repo
  alias OptimalSystemAgent.Memory.VectorEntry

  @vector_table :osa_memory_vectors
  # LRU bookkeeping for @vector_table. Kept in companion tables rather than as
  # extra elements of the {id, hash, vec} row so the row shape stays exactly
  # what callers and tests already read.
  #   @lru_table  :ordered_set of {seq, id}  — eviction order, oldest = :ets.first
  #   @seq_table  :set         of {id, seq}  — reverse index, so touching an
  #                                            existing id can drop its old seq
  @lru_table :osa_memory_vectors_lru
  @seq_table :osa_memory_vectors_seq
  @default_cache_max 2_000
  @default_embed_model "nomic-embed-text"
  @embed_timeout 5_000

  # ---------------------------------------------------------------------------
  # Availability
  # ---------------------------------------------------------------------------

  @doc """
  Whether an embedding provider is configured at all.

  This is a soft, config-only check (not a live ping) — actual
  reachability/model-availability failures still degrade gracefully via
  `embed/1` returning `{:error, _}`. Disable embeddings entirely with:

      config :optimal_system_agent, :embedding_provider, :none
  """
  @spec available?() :: boolean()
  def available? do
    Application.get_env(:optimal_system_agent, :embedding_provider, :ollama) not in [
      nil,
      false,
      :none,
      "none"
    ]
  end

  # ---------------------------------------------------------------------------
  # Embedding
  # ---------------------------------------------------------------------------

  @doc """
  Embed a piece of text. Returns `{:ok, [float, ...]}` or `{:error, reason}`.

  Never raises — all failure modes (provider disabled, HTTP error, timeout,
  malformed response) are caught and returned as `{:error, reason}` so
  callers can degrade to keyword-only recall.

  ## Injecting an embedder

  A 1-arity function under `config :optimal_system_agent, :embedding_fun`
  replaces the live provider call and must return the same
  `{:ok, [float()]} | {:error, term()}` contract:

      config :optimal_system_agent, :embedding_fun, fn _text -> {:ok, [1.0, 2.0]} end

  This exists so tests that exercise the *cache* (LRU bound, eviction order,
  persistence write-through) can drive hundreds of `embed_cached/2` calls
  without a live Ollama — a real network dependency there made those tests
  fail on assertions rather than on the behaviour they were pinning, because
  a failed embed skips the write-through path that maintains the bound. It is
  still gated by `available?/0`, so `:embedding_provider, :none` remains an
  absolute kill switch.
  """
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text) when is_binary(text) and text != "" do
    if available?() do
      case Application.get_env(:optimal_system_agent, :embedding_fun) do
        fun when is_function(fun, 1) -> fun.(text)
        _ -> do_embed(text)
      end
    else
      {:error, :embeddings_unavailable}
    end
  end

  def embed(_), do: {:error, :invalid_input}

  defp do_embed(text) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")
    model = Application.get_env(:optimal_system_agent, :embedding_model, @default_embed_model)

    case Req.post("#{url}/api/embeddings",
           json: %{model: model, prompt: text},
           receive_timeout: @embed_timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"embedding" => vec}}} when is_list(vec) and vec != [] ->
        {:ok, vec}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.debug("[Memory.Search] embed failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Embed with a per-entry cache — ETS (hot) in front of persisted SQLite
  (durable) — keyed by `id` and content hash, so an edited/merged entry's
  stale vector is never served AND a node restart never forces a re-embed of
  unchanged content. Returns `{:ok, vector}` or `{:error, reason}`.

  Lookup order: ETS (this run) -> persisted `memory_vectors` row (warms ETS
  on hit) -> live embed (persists to both on success).
  """
  @spec embed_cached(String.t(), String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed_cached(id, text) when is_binary(id) and is_binary(text) do
    ensure_table!()
    hash = :erlang.phash2(text)

    case safe_lookup(id) do
      {^hash, vec} ->
        {:ok, vec}

      _ ->
        case load_persisted(id, hash) do
          {:ok, vec} ->
            safe_insert(id, hash, vec)
            {:ok, vec}

          :miss ->
            case embed(text) do
              {:ok, vec} ->
                safe_insert(id, hash, vec)
                persist(id, hash, vec)
                {:ok, vec}

              error ->
                error
            end
        end
    end
  end

  def embed_cached(_id, _text), do: {:error, :invalid_input}

  @doc "Drop a cached vector (e.g. after an entry is deleted or content-merged)."
  @spec forget(String.t()) :: :ok
  def forget(id) when is_binary(id) do
    ensure_table!()

    try do
      :ets.delete(@vector_table, id)
      untouch(id)
    rescue
      ArgumentError -> :ok
    end

    delete_persisted(id)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Similarity / KNN
  # ---------------------------------------------------------------------------

  @doc "Cosine similarity between two equal-length numeric vectors. Returns 0.0 on any mismatch."
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity(a, b)
      when is_list(a) and is_list(b) and length(a) == length(b) and a != [] do
    {dot, norm_a, norm_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0.0, do: 0.0, else: dot / denom
  end

  def cosine_similarity(_, _), do: 0.0

  @doc """
  Cosine-similarity KNN of `entries` against a precomputed `query_vector`.

  Each entry's vector is embedded (and cached) on demand via
  `embed_cached/2`; entries whose embedding fails (e.g. empty content, or a
  transient provider error) score `0.0` on the vector component rather than
  being dropped, so a KNN failure for one entry never removes it from
  keyword-only recall.

  Returns `{scored, embeddings}` where `scored` is
  `[{cosine_similarity, entry}, ...]` sorted descending, and `embeddings` is
  a `%{id => vector}` map of everything successfully embedded (handy for
  `Memory.MMR.rerank/2`'s `:embeddings` option, avoiding recomputation).
  """
  @spec knn([float()], [map()]) :: {[{float(), map()}], %{optional(String.t()) => [float()]}}
  def knn(query_vector, entries) when is_list(query_vector) and is_list(entries) do
    {scored, embeddings} =
      Enum.reduce(entries, {[], %{}}, fn entry, {scored_acc, emb_acc} ->
        id = entry[:id] || entry["id"]
        content = entry[:content] || entry["content"] || ""

        case embed_cached(id, content) do
          {:ok, vec} ->
            sim = cosine_similarity(query_vector, vec)
            {[{sim, entry} | scored_acc], Map.put(emb_acc, id, vec)}

          {:error, _} ->
            {[{0.0, entry} | scored_acc], emb_acc}
        end
      end)

    {Enum.sort_by(scored, &elem(&1, 0), :desc), embeddings}
  end

  def knn(_query_vector, _entries), do: {[], %{}}

  # ---------------------------------------------------------------------------
  # Persisted (SQLite) vector storage
  # ---------------------------------------------------------------------------

  # Reads a persisted vector row by id. Returns `{:ok, vector}` only when the
  # row exists AND its content_hash matches (i.e. the memory hasn't changed
  # since it was embedded) — otherwise `:miss`, which the caller treats
  # exactly like a fresh entry (re-embed). Any DB error also degrades to
  # `:miss` so persistence is never a hard dependency for recall to work.
  defp load_persisted(id, hash) do
    case Repo.get(VectorEntry, id) do
      %VectorEntry{content_hash: ^hash, embedding: json} ->
        case decode_vector(json) do
          {:ok, vec} -> {:ok, vec}
          :error -> :miss
        end

      _ ->
        :miss
    end
  rescue
    e ->
      Logger.debug("[Memory.Search] load_persisted failed: #{Exception.message(e)}")
      :miss
  catch
    :exit, _ -> :miss
  end

  # Upsert a persisted vector row. Never raises — a persistence failure just
  # means this vector will be re-embedded next time (same as before this
  # layer existed), it never blocks the caller from getting its embedding.
  defp persist(id, hash, vec) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    attrs = %{
      id: id,
      content_hash: hash,
      embedding: Jason.encode!(vec),
      dim: length(vec),
      model: Application.get_env(:optimal_system_agent, :embedding_model, @default_embed_model),
      created_at: now,
      updated_at: now
    }

    case Repo.get(VectorEntry, id) do
      nil ->
        %VectorEntry{} |> VectorEntry.changeset(attrs) |> Repo.insert()

      existing ->
        existing
        |> VectorEntry.changeset(Map.put(attrs, :created_at, existing.created_at))
        |> Repo.update()
    end

    :ok
  rescue
    e ->
      Logger.debug("[Memory.Search] persist failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp delete_persisted(id) do
    case Repo.get(VectorEntry, id) do
      nil -> :ok
      row -> Repo.delete(row)
    end

    :ok
  rescue
    e ->
      Logger.debug("[Memory.Search] delete_persisted failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp decode_vector(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) and list != [] ->
        if Enum.all?(list, &is_number/1) do
          {:ok, Enum.map(list, &(&1 * 1.0))}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp decode_vector(_), do: :error

  # ---------------------------------------------------------------------------
  # ETS cache
  # ---------------------------------------------------------------------------

  defp ensure_table! do
    new_table(@vector_table, :set)
    new_table(@lru_table, :ordered_set)
    new_table(@seq_table, :set)
    :ok
  end

  defp new_table(name, type) do
    :ets.new(name, [:named_table, type, :public])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_lookup(id) do
    case :ets.lookup(@vector_table, id) do
      [{^id, hash, vec}] ->
        # A cache HIT is a use — refresh recency so a hot vector is not the one
        # evicted next.
        touch(id)
        {hash, vec}

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp safe_insert(id, hash, vec) do
    :ets.insert(@vector_table, {id, hash, vec})
    touch(id)
    enforce_cache_cap()
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # LRU bound
  # ---------------------------------------------------------------------------

  @doc """
  Maximum number of vectors held in the `:osa_memory_vectors` ETS cache.

  Exposed so tests can assert the bound and operators can tune it:

      config :optimal_system_agent, :memory_vector_cache_max, 5_000

  `0` (or a non-positive/invalid value) disables eviction, restoring the old
  unbounded behaviour — deliberately opt-in, never the default.
  """
  @spec cache_max() :: non_neg_integer()
  def cache_max do
    case Application.get_env(:optimal_system_agent, :memory_vector_cache_max, @default_cache_max) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_cache_max
    end
  end

  @doc """
  Create the vector cache and its LRU bookkeeping tables from a long-lived
  process.

  Called from `Application.start/2` (Phase 2). Same hazard as
  `Infra.BoundedTable.init_tables/0`: lazily created named ETS tables are owned
  by the first caller, and if that is a transient process the tables die with
  it. Losing `@lru_table`/`@seq_table` while `@vector_table` survives leaves
  cached vectors with no recency entry, so eviction picks the wrong rows. The
  lazy `ensure_table!/0` path remains for callers running without the
  application started.
  """
  @spec init_tables() :: :ok
  def init_tables, do: ensure_table!()

  @doc "Number of vectors currently cached in ETS. Diagnostics + bound tests."
  @spec cache_size() :: non_neg_integer()
  def cache_size do
    case :ets.info(@vector_table, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc """
  Drop every cached vector (ETS only — the durable `memory_vectors` rows are
  untouched, so this costs a disk read per entry, never a re-embed).
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    ensure_table!()
    :ets.delete_all_objects(@vector_table)
    :ets.delete_all_objects(@lru_table)
    :ets.delete_all_objects(@seq_table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Mark `id` as most-recently-used. Monotonic integers give a strictly
  # increasing recency key without a shared counter row to contend on.
  defp touch(id) do
    case :ets.lookup(@seq_table, id) do
      [{^id, old_seq}] -> :ets.delete(@lru_table, old_seq)
      _ -> :ok
    end

    seq = System.unique_integer([:monotonic, :positive])
    :ets.insert(@lru_table, {seq, id})
    :ets.insert(@seq_table, {id, seq})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Drop the LRU bookkeeping for `id` (called on eviction and on forget/1).
  defp untouch(id) do
    case :ets.lookup(@seq_table, id) do
      [{^id, seq}] -> :ets.delete(@lru_table, seq)
      _ -> :ok
    end

    :ets.delete(@seq_table, id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Evict least-recently-used rows until the cache is back under the cap.
  # Bounded by construction: each pass removes the single oldest key, and the
  # loop's own guard is the table size, so it always terminates.
  defp enforce_cache_cap do
    max = cache_max()
    if max > 0, do: evict_down_to(max)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict_down_to(max) do
    if cache_size() > max do
      case :ets.first(@lru_table) do
        :"$end_of_table" ->
          # Bookkeeping lost (e.g. the LRU table was cleared out from under us)
          # while the vector table is over cap — rebuild recency from scratch
          # rather than spin. Correctness is unaffected: SQLite still holds
          # every vector.
          :ets.delete_all_objects(@vector_table)
          :ets.delete_all_objects(@seq_table)
          :ok

        seq ->
          case :ets.lookup(@lru_table, seq) do
            [{^seq, id}] ->
              :ets.delete(@vector_table, id)
              untouch(id)

            _ ->
              :ets.delete(@lru_table, seq)
          end

          evict_down_to(max)
      end
    else
      :ok
    end
  end
end
