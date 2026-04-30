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

  alias OptimalSystemAgent.Memory.Store

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
    GenServer.call(Store, {:save, content, opts}, :infinity)
  end

  @doc """
  Search memories by keyword query.

  Searches the in-memory ETS keyword index first, then falls back to SQLite
  FTS5 for entries not yet indexed. Results are ranked by a weighted
  relevance score: 30% base keyword match + 50% contextual signal weight
  + 20% recency. Access counts are bumped on every successful recall.

  Options:
    - `:category` — filter by category atom or string
    - `:scope`    — filter by scope atom or string
    - `:limit`    — maximum entries to return (default: 10)

  Returns `{:ok, [entry, ...]}`.
  """
  @spec recall(String.t(), keyword()) :: {:ok, [map()]}
  def recall(query, opts \\ []) when is_binary(query) do
    GenServer.call(Store, {:recall, query, opts}, :infinity)
  end

  @doc """
  Retrieve a single memory entry by its ID.

  Returns `{:ok, entry}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    GenServer.call(Store, {:get, id}, :infinity)
  end

  @doc """
  Return the most recent memory entries, newest first.

  Returns `{:ok, [entry, ...]}`.
  """
  @spec recent(pos_integer()) :: {:ok, [map()]}
  def recent(limit \\ 10) when is_integer(limit) and limit > 0 do
    GenServer.call(Store, {:recent, limit}, :infinity)
  end

  @doc """
  Delete a memory entry by ID.

  Removes from both SQLite and the ETS index.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) when is_binary(id) do
    GenServer.call(Store, {:delete, id}, :infinity)
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
    GenServer.call(Store, {:search_sessions, query, opts}, :infinity)
  end

  @doc """
  Return aggregate memory statistics.

  Returns a map with keys: total, by_category, by_scope, by_source, avg_relevance.
  """
  @spec stats() :: {:ok, map()}
  def stats do
    GenServer.call(Store, :stats, :infinity)
  end

  @doc """
  Rebuild the in-memory ETS index from SQLite.

  Use this to recover from an ETS table being dropped (e.g. after a node crash
  that left the GenServer restarted but the application ETS tables gone).

  Returns `:ok`.
  """
  @spec rebuild_index() :: :ok
  def rebuild_index do
    GenServer.call(Store, :rebuild_index, :infinity)
  end

  @doc """
  Regenerate `~/.osa/MEMORY.md` from all current SQLite memory entries.

  This is called automatically on save but can be triggered manually to
  repair a missing or stale file.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec regenerate_md() :: :ok | {:error, term()}
  def regenerate_md do
    GenServer.call(Store, :regenerate_md, :infinity)
  end
end
