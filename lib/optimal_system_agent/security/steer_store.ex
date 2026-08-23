defmodule OptimalSystemAgent.Security.SteerStore do
  @moduledoc """
  Session-scoped store for pending steer directives (Tier 3 #14).

  ETS-backed GenServer keyed by session id via a Registry, started lazily.
  Holds at most one pending steer directive per session (the latest inject
  overwrites any prior pending one).
  """

  use GenServer

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

  @doc "Stop the store for a session."
  @spec stop(String.t()) :: :ok
  def stop(session_id) when is_binary(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  end

  @doc "Put a steer directive (overwrites any pending one)."
  @spec put(String.t(), map()) :: :ok
  def put(session_id, directive) when is_binary(session_id) and is_map(directive) do
    GenServer.call(via(session_id), {:put, directive}, 5_000)
  end

  @doc "Get the pending steer directive."
  @spec get(String.t()) :: {:ok, map()} | :none
  def get(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :get, 5_000)
  end

  @doc "Clear the pending steer directive."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :clear, 5_000)
  end

  ## ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(_session_id) do
    table = :ets.new(__MODULE__, [:set, :private])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, directive}, _from, state) do
    :ets.insert(state.table, {:directive, directive})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    reply =
      case :ets.lookup(state.table, :directive) do
        [{:directive, d}] -> {:ok, d}
        [] -> :none
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete(state.table, :directive)
    {:reply, :ok, state}
  end

  ## ── Registry helpers ──────────────────────────────────────────────────

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.Security.SteerStoreRegistry, session_id}}
  end
end
