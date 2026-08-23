defmodule OptimalSystemAgent.Security.CodeFixStore do
  @moduledoc """
  Session-scoped store for code-fix records (Tier 3 #15).

  ETS-backed GenServer keyed by session id via a Registry, started lazily.
  Holds the fix_before/fix_after records keyed by finding key.
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

  @doc "Put a code-fix record (keyed by finding_key)."
  @spec put(String.t(), map()) :: :ok
  def put(session_id, fix) when is_binary(session_id) and is_map(fix) do
    GenServer.call(via(session_id), {:put, fix}, 5_000)
  end

  @doc "Get a code-fix record by finding key."
  @spec get(String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(session_id, finding_key)
      when is_binary(session_id) and is_binary(finding_key) do
    GenServer.call(via(session_id), {:get, finding_key}, 5_000)
  end

  @doc "List all code-fix records for a session."
  @spec list(String.t()) :: [map()]
  def list(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :list, 5_000)
  end

  @doc "Delete a code-fix record by finding key."
  @spec delete(String.t(), String.t()) :: :ok | :not_found
  def delete(session_id, finding_key)
      when is_binary(session_id) and is_binary(finding_key) do
    GenServer.call(via(session_id), {:delete, finding_key}, 5_000)
  end

  ## ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(_session_id) do
    table = :ets.new(__MODULE__, [:set, :private])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, fix}, _from, state) do
    :ets.insert(state.table, {fix.finding_key, fix})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, finding_key}, _from, state) do
    reply =
      case :ets.lookup(state.table, finding_key) do
        [{^finding_key, fix}] -> {:ok, fix}
        [] -> :not_found
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    fixes =
      :ets.foldl(fn {_k, v}, acc -> [v | acc] end, [], state.table)
      |> Enum.sort_by(& &1.recorded_at, {:desc, DateTime})

    {:reply, fixes, state}
  end

  @impl true
  def handle_call({:delete, finding_key}, _from, state) do
    case :ets.member(state.table, finding_key) do
      true ->
        :ets.delete(state.table, finding_key)
        {:reply, :ok, state}

      false ->
        {:reply, :not_found, state}
    end
  end

  ## ── Registry helpers ──────────────────────────────────────────────────

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.Security.CodeFixStoreRegistry, session_id}}
  end
end
