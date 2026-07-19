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

  ## Vector storage

  Chose an **in-memory ETS cache** (`:osa_memory_vectors`, keyed by memory
  entry id, storing `{content_hash, vector}`), NOT a persisted SQLite/
  sqlite-vec column. Reasons:

    1. `sqlite-vec` is a native SQLite extension; the `ecto_sqlite3`/`exqlite`
       stack this project uses does not load arbitrary loadable extensions
       out of the box, and wiring that up is its own infra project.
    2. Persisting vectors in the `memories` table requires a schema migration
       (`priv/repo/migrations/`), which sits outside this task's owned file
       set (`lib/optimal_system_agent/memory/*`) and is shared/lead-owned
       territory per the task's disjoint-ownership rule.
    3. Vectors are cheap to recompute lazily (one embedding call per memory,
       cached for the life of the node) and OSA's memory table size is small
       enough that a full re-embed after a restart is not a concern.

  A follow-up can add a persisted `embedding` column (same cache-key shape)
  via a migration owned by the lead/DB-owning agent without changing this
  module's public API.
  """

  require Logger

  @vector_table :osa_memory_vectors
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
  """
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text) when is_binary(text) and text != "" do
    if available?() do
      do_embed(text)
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
  Embed with a per-entry ETS cache, keyed by `id` and content hash (so an
  edited/merged entry's stale vector is never served). Returns `{:ok, vector}`
  or `{:error, reason}`.
  """
  @spec embed_cached(String.t(), String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed_cached(id, text) when is_binary(id) and is_binary(text) do
    ensure_table!()
    hash = :erlang.phash2(text)

    case safe_lookup(id) do
      {^hash, vec} ->
        {:ok, vec}

      _ ->
        case embed(text) do
          {:ok, vec} ->
            safe_insert(id, hash, vec)
            {:ok, vec}

          error ->
            error
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
    rescue
      ArgumentError -> :ok
    end

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
  # ETS cache
  # ---------------------------------------------------------------------------

  defp ensure_table! do
    try do
      :ets.new(@vector_table, [:named_table, :set, :public])
    rescue
      ArgumentError -> :ok
    end
  end

  defp safe_lookup(id) do
    case :ets.lookup(@vector_table, id) do
      [{^id, hash, vec}] -> {hash, vec}
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp safe_insert(id, hash, vec) do
    :ets.insert(@vector_table, {id, hash, vec})
  rescue
    ArgumentError -> :ok
  end
end
