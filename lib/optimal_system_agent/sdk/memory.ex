defmodule OptimalSystemAgent.SDK.Memory do
  @moduledoc """
  SDK wrapper for the Agent.Memory subsystem.

  Provides access to persistent memory: recall, search, remember,
  and session message history.
  """

  alias OptimalSystemAgent.Agent.Memory

  @doc """
  Recall all persistent memories (full MEMORY.md dump).
  """
  @spec recall() :: String.t()
  def recall do
    Memory.recall()
  end

  @doc """
  Recall memories relevant to a specific query within a token budget.

  Uses keyword extraction + inverted index for fast semantic lookup.
  Returns a formatted context block.
  """
  @spec recall_relevant(String.t(), pos_integer()) :: String.t()
  def recall_relevant(message, max_tokens \\ 2000) do
    Memory.recall_relevant(message, max_tokens)
  end

  @doc """
  Save a key insight to persistent memory with importance scoring.

  Categories: "general", "decision", "pattern", "solution", "context"
  """
  @spec remember(String.t(), String.t()) :: :ok
  def remember(content, category \\ "general") do
    Memory.remember(content, category)
  end

  @doc """
  Search memories by keyword with optional filters.

  ## Options
  - `:category` — filter by category
  - `:limit` — max results (default: 10)
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    Memory.search(query, opts)
  end

  @doc "Load a session's full message history."
  @spec load_session(String.t()) :: [map()]
  def load_session(session_id) do
    Memory.load_session(session_id)
  end

  @doc "List all stored sessions with metadata."
  @spec list_sessions() :: [map()]
  def list_sessions do
    Memory.list_sessions()
  end

  @doc "Search across session messages."
  @spec search_messages(String.t(), keyword()) :: [map()]
  def search_messages(query, opts \\ []) do
    Memory.search_messages(query, opts)
  end

  @doc "Get memory subsystem statistics."
  @spec stats() :: map()
  def stats do
    Memory.memory_stats()
  end

  @doc "Archive old entries (default: older than 30 days)."
  @spec archive(pos_integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def archive(max_age_days \\ 30) do
    Memory.archive(max_age_days)
  end
end
