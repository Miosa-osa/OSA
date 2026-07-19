# Hybrid RAG Recall

Vector-KNN + MMR diversity re-ranking + query expansion, fused with the
existing keyword/FTS scoring path in `Memory.Scoring`. Reference: grok
`xai-grok-memory/src/search.rs` ("Hybrid search combining FTS5 BM25 +
sqlite-vec KNN + temporal decay + source weighting + MMR").

Every piece degrades independently and gracefully — a missing embedding
provider, an unreachable Ollama, or a failed embed call never blocks recall;
callers fall back to keyword-only scoring at each layer.

---

## Vector KNN (`OptimalSystemAgent.Memory.Search`)

**Embedding provider** — OSA has no dedicated embedding-provider abstraction;
rather than add a whole new provider subsystem, this reuses the existing
local Ollama connection (`:ollama_url`) and calls Ollama's native `POST
/api/embeddings` endpoint. Requires an embedding-capable model pulled
locally (e.g. `nomic-embed-text`, the default).

| Config Key | Default | Effect |
|---|---|---|
| `embedding_provider` | `:ollama` | Set to `:none` (or `false`/`nil`) to disable embeddings entirely — recall degrades to keyword-only scoring. |
| `embedding_model` | `"nomic-embed-text"` | Model name passed to Ollama's `/api/embeddings`. |

**Persisted vector store** — embeddings are durably stored one row per
memory `id` in a `memory_vectors` table
(`priv/repo/migrations/20260719000001_create_memory_vectors.exs`, schema
`Memory.VectorEntry`) in the same SQLite database the memory store uses. An
in-memory ETS table (`:osa_memory_vectors`) sits in front as a warm read
cache — first access after boot lazily loads from SQLite, subsequent lookups
in the same run stay ETS-speed.

Why a plain column instead of the `sqlite-vec` extension: OSA's SQLite access
goes through `ecto_sqlite3`/`exqlite`, which does not expose a way to
`load_extension` an arbitrary native extension without patching `exqlite`'s
NIF build. Each embedding is instead stored as a JSON-encoded float array in
a `:text` column, and cosine similarity/KNN stays an in-Elixir scan
(`cosine_similarity/2`, `knn/2`) — fine at OSA's memory-table scale (hundreds
to low thousands of rows).

**Invalidation** — every persisted row carries `content_hash`
(`:erlang.phash2/1` of the embedded text). A mismatched hash on lookup
(content changed since embedding) is treated as a cache miss: the entry is
re-embedded and the row upserted. `forget/1` deletes both the ETS entry and
the persisted row.

---

## MMR Diversity Re-ranking (`OptimalSystemAgent.Memory.MMR`)

Greedy Maximal Marginal Relevance re-ranking over hybrid-scored candidates:

```
MMR(d) = lambda * relevance(d) - (1 - lambda) * max_sim(d, selected)
```

Prevents the memory block injected into context from filling up with several
near-duplicate phrasings of the same fact — which would otherwise waste the
tight memory-context token budget the context builder protects.

- `lambda` (default `0.7`) trades relevance vs diversity: `1.0` = pure
  relevance ranking, `0.0` = pure diversity.
- Pairwise similarity prefers cosine similarity over embedding vectors (via
  `Memory.Search`) when available, and falls back to keyword Jaccard overlap
  (`Memory.Scoring.keyword_overlap/2`) when embeddings are missing for one or
  both entries — so MMR still functions in embeddings-unavailable /
  keyword-only mode.

---

## Query Expansion (`OptimalSystemAgent.Memory.QueryExpansion`)

Lightweight, dependency-free expansion of a query's keyword set — a small
hand-curated synonym dictionary (e.g. `"bug" <-> "issue" <-> "defect"`) plus
cheap morphological stemming (plural/gerund/past-tense suffix stripping) —
feeding the lexical scoring path (`Memory.Scoring`, FTS5/keyword overlap) so
it can match memories using a related but different word than the query.

Pure and synchronous: no LLM call, no network, safe to run on every recall
without adding latency or a new failure mode. It complements (does not
replace) the vector-KNN half.

---

## See Also

- [Memory Overview](overview.md)
- [Context Compactor — This-Cycle Additions](../agent-loop/compactor.md#this-cycle-additions-wave-2b2c)
- [Configuration → Agent Behavior → Memory / embeddings](../../getting-started/configuration.md#agent-behavior-wave-2b2c)
