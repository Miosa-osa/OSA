defmodule OptimalSystemAgent.Security.PlaybookStore do
  @moduledoc """
  Session-scoped store for the active playbook state.

  Holds the current playbook id, phase index, and phase status per session.
  ETS-backed GenServer keyed by session id via a Registry, started lazily.
  """

  use GenServer

  @type state :: %{
          playbook_id: atom(),
          phase_index: non_neg_integer(),
          status: :pending | :in_progress | :complete | :skipped
        }

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

  @doc "Get the current playbook state."
  @spec get(String.t()) :: {:ok, state()} | :not_found
  def get(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :get, 5_000)
  end

  @doc "Set the current playbook, phase index, and status."
  @spec set(String.t(), atom(), non_neg_integer(), atom()) :: :ok
  def set(session_id, playbook_id, phase_index, status)
      when is_binary(session_id) and is_atom(playbook_id) and is_integer(phase_index) and
             is_atom(status) do
    GenServer.call(via(session_id), {:set, playbook_id, phase_index, status}, 5_000)
  end

  ## ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(_session_id) do
    table = :ets.new(__MODULE__, [:set, :private])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    reply =
      case :ets.lookup(state.table, :state) do
        [state: s] -> {:ok, s}
        [] -> :not_found
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:set, playbook_id, phase_index, status}, _from, state) do
    s = %{playbook_id: playbook_id, phase_index: phase_index, status: status}
    :ets.insert(state.table, {:state, s})
    {:reply, :ok, state}
  end

  ## ── Registry helpers ──────────────────────────────────────────────────

  defp via(session_id) do
    {:via, Registry, {OptimalSystemAgent.Security.PlaybookStoreRegistry, session_id}}
  end
end
