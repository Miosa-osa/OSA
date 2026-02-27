defmodule OptimalSystemAgent.SDK.Session do
  @moduledoc """
  Session lifecycle management for the SDK.

  Wraps `DynamicSupervisor` + `SessionRegistry` + `Agent.Loop` to provide
  a clean CRUD API for agent sessions.

  Each session is a supervised `Agent.Loop` GenServer identified by a unique
  session_id. Sessions can be created, resumed, closed, and listed.
  """

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Memory

  @supervisor OptimalSystemAgent.Channels.Supervisor

  @doc """
  Create a new session with a unique ID.

  Starts an `Agent.Loop` under the DynamicSupervisor with the given options.

  ## Options
  - `:session_id` — unique identifier (auto-generated if omitted)
  - `:user_id` — user identifier
  - `:channel` — channel atom (default: `:sdk`)
  - `:extra_tools` — additional tool definitions for this session
  """
  @spec create(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, &generate_id/0)

    loop_opts = [
      session_id: session_id,
      user_id: Keyword.get(opts, :user_id),
      channel: Keyword.get(opts, :channel, :sdk),
      extra_tools: Keyword.get(opts, :extra_tools, [])
    ]

    case DynamicSupervisor.start_child(@supervisor, {Loop, loop_opts}) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, {:already_started, _}} -> {:ok, session_id}
      error -> error
    end
  end

  @doc """
  Resume an existing session (or create if not found).

  If a Loop process exists for the session_id, returns it.
  Otherwise creates a new one.
  """
  @spec resume(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume(session_id, opts \\ []) do
    if alive?(session_id) do
      {:ok, session_id}
    else
      create(Keyword.put(opts, :session_id, session_id))
    end
  end

  @doc """
  Close a session and stop its Loop process.
  """
  @spec close(String.t()) :: :ok | {:error, :not_found}
  def close(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if a session is alive.
  """
  @spec alive?(String.t()) :: boolean()
  def alive?(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  @doc """
  List all active session IDs.
  """
  @spec list() :: [String.t()]
  def list do
    Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Get messages for a session from the persistent memory store.
  """
  @spec get_messages(String.t()) :: [map()]
  def get_messages(session_id) do
    Memory.load_session(session_id)
  rescue
    _ -> []
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
