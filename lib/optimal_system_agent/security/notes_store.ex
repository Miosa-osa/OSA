defmodule OptimalSystemAgent.Security.NotesStore do
  @moduledoc """
  Session-scoped store for structured security notes.

  The intelligence-layer modules (`StructuredNotes`, `ShadowGraph`,
  `TaskDifficulty`, `VulnDeduplication`) are pure functions — they hold no
  state. This module owns the per-session note set: a process registry keyed
  by session id, backed by an ETS table for concurrent reads, with a
  GenServer serializing writes.

  ## Lifecycle

  A store is started lazily per session via `ensure_started/1` and torn down
  when the session ends. The ETS table is `heir`-owned by the GenServer so it
  survives the caller's death but dies with the owning process.

  ## Shape

  Notes are stored as the maps produced by `StructuredNotes.build_note/2`,
  keyed by their `key` field. The store also caches the last-built
  `ShadowGraph` so repeated graph queries don't reprocess the full note set.
  """

  use GenServer

  require Logger

  alias OptimalSystemAgent.Security.{StructuredNotes, ShadowGraph}

  @type note :: StructuredNotes.note()

  ## ── Public API ────────────────────────────────────────────────────────

  @doc "Start the store for a session if it isn't already running."
  @spec ensure_started(String.t()) :: {:ok, pid} | {:error, term()}
  def ensure_started(session_id) when is_binary(session_id) do
    name = via(session_id)

    case GenServer.whereis(name) do
      nil -> GenServer.start_link(__MODULE__, session_id, name: name)
      pid -> {:ok, pid}
    end
  end

  @doc "Stop and clear the store for a session."
  @spec stop(String.t()) :: :ok
  def stop(session_id) when is_binary(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  end

  @doc "Add or replace a note. Validates against the category schema first."
  @spec put(String.t(), String.t(), map()) :: {:ok, note()} | {:error, String.t()}
  def put(session_id, key, data) when is_binary(session_id) and is_binary(key) and is_map(data) do
    GenServer.call(via(session_id), {:put, key, data}, 5_000)
  end

  @doc "Get a single note by key."
  @spec get(String.t(), String.t()) :: {:ok, note()} | :not_found
  def get(session_id, key) when is_binary(session_id) and is_binary(key) do
    GenServer.call(via(session_id), {:get, key}, 5_000)
  end

  @doc "List all notes for a session, optionally filtered by category."
  @spec list(String.t(), atom() | nil) :: [note()]
  def list(session_id, category \\ nil) when is_binary(session_id) do
    GenServer.call(via(session_id), {:list, category}, 5_000)
  end

  @doc "Delete a note by key."
  @spec delete(String.t(), String.t()) :: :ok | :not_found
  def delete(session_id, key) when is_binary(session_id) and is_binary(key) do
    GenServer.call(via(session_id), {:delete, key}, 5_000)
  end

  @doc "Clear all notes for a session."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :clear, 5_000)
  end

  @doc "Count notes, optionally filtered by category."
  @spec count(String.t(), atom() | nil) :: non_neg_integer()
  def count(session_id, category \\ nil) when is_binary(session_id) do
    GenServer.call(via(session_id), {:count, category}, 5_000)
  end

  @doc """
  Build (or rebuild) the ShadowGraph from the current notes and cache it.

  Returns the graph. Subsequent `graph/1` calls return the cached value until
  a note is added, replaced, or deleted, which invalidates the cache.
  """
  @spec build_graph(String.t()) :: ShadowGraph.graph()
  def build_graph(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :build_graph, 5_000)
  end

  @doc "Get the cached graph, rebuilding if the cache is stale."
  @spec graph(String.t()) :: ShadowGraph.graph()
  def graph(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :get_graph, 5_000)
  end

  ## ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(session_id) do
    table = :ets.new(__MODULE__, [:set, :private, read_concurrency: true])

    state = %{
      session_id: session_id,
      table: table,
      graph: nil,
      graph_valid: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, data}, _from, state) do
    case StructuredNotes.create(key, data) do
      {:ok, note} ->
        :ets.insert(state.table, {key, note})
        {:reply, {:ok, note}, %{state | graph_valid: false}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    reply =
      case :ets.lookup(state.table, key) do
        [{^key, note}] -> {:ok, note}
        [] -> :not_found
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:list, category}, _from, state) do
    notes =
      :ets.foldl(
        fn
          {_key, note}, acc when is_nil(category) -> [note | acc]
          {_key, %{category: ^category} = note}, acc -> [note | acc]
          _, acc -> acc
        end,
        [],
        state.table
      )

    {:reply, Enum.reverse(notes), state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    case :ets.member(state.table, key) do
      true ->
        :ets.delete(state.table, key)
        {:reply, :ok, %{state | graph_valid: false}}

      false ->
        {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | graph: nil, graph_valid: false}}
  end

  @impl true
  def handle_call({:count, category}, _from, state) do
    count =
      :ets.foldl(
        fn
          {_key, %{category: ^category}}, acc -> acc + 1
          {_key, _note}, acc when is_nil(category) -> acc + 1
          _, acc -> acc
        end,
        0,
        state.table
      )

    {:reply, count, state}
  end

  @impl true
  def handle_call(:build_graph, _from, state) do
    notes = :ets.foldl(fn {_k, v}, acc -> [v | acc] end, [], state.table)
    graph = ShadowGraph.update_from_notes(ShadowGraph.new(), Enum.reverse(notes))
    {:reply, graph, %{state | graph: graph, graph_valid: true}}
  end

  @impl true
  def handle_call(:get_graph, _from, state) do
    if state.graph_valid and state.graph != nil do
      {:reply, state.graph, state}
    else
      notes = :ets.foldl(fn {_k, v}, acc -> [v | acc] end, [], state.table)
      graph = ShadowGraph.update_from_notes(ShadowGraph.new(), Enum.reverse(notes))
      {:reply, graph, %{state | graph: graph, graph_valid: true}}
    end
  end

  ## ── Registry helpers ──────────────────────────────────────────────────

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.Security.NotesStoreRegistry, session_id}}
  end
end
