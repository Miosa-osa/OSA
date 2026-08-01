# Taxonomy and Injector

The taxonomy system classifies memory entries into categories and scopes, enabling the injector to filter and rank entries precisely for each LLM prompt context. Both modules are planned additions to `miosa_memory`; OSA's alias modules (`Agent.Memory.Taxonomy`, `Agent.Memory.Injector`) define the stable interface.

## Taxonomy Entry

A taxonomy entry wraps a memory value with classification metadata:

```elixir
# MiosaMemory.Taxonomy.t()
%{
  content:    "Always use parameterized queries for SQL",
  category:   :pattern,
  scope:      :global,
  created_at: ~U[2026-03-08 10:00:00Z],
  accessed_at: ~U[2026-03-08 10:05:00Z],
  tags:       ["sql", "security"],
  frequency:  3
}
```

## Categories

Categories describe the _kind of knowledge_ an entry represents:

| Category | `:category` value | Description | Typical source |
|----------|------------------|-------------|----------------|
| Pattern | `:pattern` | A recurring approach or structure | Learning engine `observe/1` |
| Solution | `:solution` | A proven fix for a known error class | Learning engine `error/3` |
| Decision | `:decision` | An architecture or design choice with rationale | `/mem-save decision` |
| Preference | `:preference` | A user-stated style or workflow preference | `/mem-save context` |

Categories are mutually exclusive per entry. The learning engine assigns category automatically from the interaction type. User-initiated saves use the category passed to `/mem-save`.

## Scopes

Scopes describe the _reach_ of an entry — how broadly it should be injected:

| Scope | `:scope` value | Injected when | Example |
|-------|---------------|--------------|---------|
| Session | `:session` | Only within the originating session | "User prefers concise answers today" |
| Workspace | `:workspace` | Whenever the same working directory is active | "This project uses Ecto 3.12" |
| Global | `:global` | Always, regardless of session or workspace | "Never add Co-Authored-By to commits" |

Scope is resolved at write time by `Taxonomy.new/2` using cues from the entry content and the current session context.

## Taxonomy API

```elixir
alias OptimalSystemAgent.Agent.Memory.Taxonomy

# Create a new classified entry
entry = Taxonomy.new("Always use parameterized queries",
  category: :pattern,
  scope: :global,
  tags: ["sql", "security"]
)

# Auto-classify content (returns :pattern | :solution | :decision | :preference)
category = Taxonomy.categorize("Connection pool sizing recommendation")

# Filter a list of entries by criteria
relevant = Taxonomy.filter_by(entries, %{
  category: :pattern,
  scope: :workspace
})

# Introspect valid values
Taxonomy.categories()   # [:pattern, :solution, :decision, :preference]
Taxonomy.scopes()       # [:session, :workspace, :global]

# Validate
Taxonomy.valid_category?(:pattern)   # true
Taxonomy.valid_scope?(:workspace)    # true

# Update access time (called on retrieval for recency tracking)
updated = Taxonomy.touch(entry)
```

## Injector

`MiosaMemory.Injector` (aliased as `OptimalSystemAgent.Agent.Memory.Injector`) takes a filtered set of taxonomy entries and formats them for insertion into an LLM prompt.

### Injection Context

The `injection_context` struct carries the current session state used to filter relevance:

```elixir
# MiosaMemory.Injector.injection_context()
%{
  session_id:   "sess-abc123",
  working_dir:  "/home/user/projects/OptimalSystemAgent",
  current_query: "How do I configure the connection pool?",
  token_budget: 2000
}
```

### Injection API

```elixir
alias OptimalSystemAgent.Agent.Memory.Injector

# Filter entries relevant to the current context, respecting scope and budget
filtered = Injector.inject_relevant(entries, injection_context)

# Format filtered entries as prompt-ready strings
prompt_block = Injector.format_for_prompt(filtered)
```

### Filtering Logic

`inject_relevant/2` applies the following filters in order:

1. **Scope gate**: drop `:session` entries whose `session_id` does not match the current session; drop `:workspace` entries whose inferred working directory does not match.
2. **Relevance ranking**: score each entry by keyword overlap between `current_query` and the entry's content + tags + category. Higher overlap = higher rank.
3. **Recency weighting**: multiply score by `Episodic.temporal_decay(entry.accessed_at, half_life)`. Stale entries rank lower.
4. **Budget cap**: take entries in ranked order until `token_budget` is reached.

### Format Output

`format_for_prompt/1` produces a compact block inserted as a system-role message:

```
[memory:pattern] Always use parameterized queries for SQL (sql, security)
[memory:decision] Database: use Mnesia for production, ETS for tests (architecture)
[memory:solution] JSONDecodeError → strip markdown fences before parsing (llm, json)
```

Each line is prefixed with `[memory:<category>]` and suffixed with a parenthesized tag list. Entries longer than a configurable character limit are truncated with `...`.

## Integration in the Agent Loop

```
Agent Loop (per turn)
    │
    ├─ 1. Load session messages
    │
    ├─ 2. Build injection_context from session state
    │
    ├─ 3. Load taxonomy entries:
    │      MiosaMemory.Store.search(collection, current_query)
    │      → returns raw entries
    │
    ├─ 4. Classify (if not yet classified):
    │      Taxonomy.categorize(content) for each entry
    │
    ├─ 5. Filter and rank:
    │      Injector.inject_relevant(entries, injection_context)
    │
    ├─ 6. Format:
    │      Injector.format_for_prompt(filtered)
    │      → produces [memory:...] block
    │
    └─ 7. Inject as system message before conversation history
```

## Relationship to Existing Store

The taxonomy and injector are a classification and retrieval layer on top of `MiosaMemory.Store.ETS`. They do not replace the store — they add structured metadata and ranking to what the store returns. An entry lives in the store as its raw value; taxonomy wraps it with `:category`, `:scope`, and recency fields at classification time.

## See Also

- [memory-store.md](./memory-store.md) — Underlying storage that taxonomy entries live in
- [learning.md](./learning.md) — Primary producer of pattern and solution entries
- [episodic.md](./episodic.md) — Episodic entries that share the scope/category model
- [overview.md](./overview.md) — Position of taxonomy in the 5-layer stack
