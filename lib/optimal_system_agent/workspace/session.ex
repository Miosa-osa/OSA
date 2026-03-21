defmodule OptimalSystemAgent.Workspace.Session do
  @moduledoc """
  Ephemeral UI connection to a persistent workspace.

  Sessions are short-lived: they connect to a workspace, receive a full state
  snapshot, and get live broadcasts for every subsequent change. When a session
  disconnects — due to a network drop, tab close, or explicit call — the
  workspace continues running and accumulating state. Reconnecting creates a
  new session that gets the full current snapshot.

  ## Design

  - Workspace state is authoritative and durable (SQLite-backed GenServer)
  - Sessions are in-memory only — nothing is lost if a session dies
  - PubSub topic `"workspace:{workspace_id}"` carries state broadcasts
  - Multiple concurrent sessions per workspace are supported

  ## Usage

      # Connect a UI client to a workspace
      {:ok, session_id, snapshot} = Session.connect("ws_abc123", session_id: "ui_456")

      # Subscribe to live updates (Phoenix.PubSub)
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "workspace:ws_abc123")

      # ... receive {:workspace_update, workspace_id, event, payload} messages ...

      # Disconnect (workspace persists)
      :ok = Session.disconnect("ui_456")
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Workspace.Workspace

  @session_table :osa_workspace_sessions

  # ── ETS Initialization ────────────────────────────────────────────────────

  @doc "Create the sessions ETS table. Called from application start."
  def init_table do
    :ets.new(@session_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Connect a session to a workspace.

  If the workspace GenServer is not running, it will be started on demand
  (requires a started `DynamicSupervisor` for workspaces). Returns
  `{:ok, session_id, workspace_snapshot}` on success.

  ## Options
  - `:session_id`    — explicit session id (generated if omitted)
  - `:metadata`      — arbitrary map stored alongside the session
  """
  @spec connect(String.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def connect(workspace_id, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    metadata = Keyword.get(opts, :metadata, %{})

    case Workspace.get_state(workspace_id) do
      {:ok, snapshot} ->
        now = DateTime.utc_now()

        record = %{
          session_id: session_id,
          workspace_id: workspace_id,
          metadata: metadata,
          connected_at: now,
          last_seen: now
        }

        :ets.insert(@session_table, {session_id, record})
        Logger.info("[Session] #{session_id} connected to workspace #{workspace_id}")

        {:ok, session_id, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Disconnect a session.

  The session record is removed from ETS. The workspace continues unchanged.
  Returns `:ok` regardless of whether the session existed.
  """
  @spec disconnect(String.t()) :: :ok
  def disconnect(session_id) do
    case :ets.lookup(@session_table, session_id) do
      [{_, %{workspace_id: workspace_id}}] ->
        :ets.delete(@session_table, session_id)
        Logger.info("[Session] #{session_id} disconnected from workspace #{workspace_id}")

      [] ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "List all active sessions for a workspace."
  @spec list_sessions(String.t()) :: [map()]
  def list_sessions(workspace_id) do
    :ets.match_object(@session_table, {:_, %{workspace_id: workspace_id}})
    |> Enum.map(fn {_, record} -> record end)
    |> Enum.sort_by(& &1.connected_at)
  rescue
    _ -> []
  end

  @doc "Get a session record by session_id."
  @spec get_session(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(session_id) do
    case :ets.lookup(@session_table, session_id) do
      [{_, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc "Count of active sessions for a workspace."
  @spec session_count(String.t()) :: non_neg_integer()
  def session_count(workspace_id) do
    workspace_id |> list_sessions() |> length()
  end

  @doc "Update the last_seen timestamp for a session."
  @spec touch(String.t()) :: :ok
  def touch(session_id) do
    case :ets.lookup(@session_table, session_id) do
      [{_, record}] ->
        :ets.insert(@session_table, {session_id, %{record | last_seen: DateTime.utc_now()}})
        :ok

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── Broadcast ─────────────────────────────────────────────────────────────

  @doc """
  Broadcast a workspace state event to all connected sessions.

  Sessions subscribed to `"workspace:{workspace_id}"` via Phoenix.PubSub
  will receive `{:workspace_update, workspace_id, event, payload}`.

  ## Parameters
  - `workspace_id` — the workspace broadcasting
  - `event`        — atom describing what changed (e.g. `:task_updated`)
  - `payload`      — the changed data
  """
  @spec broadcast(String.t(), atom(), map()) :: :ok
  def broadcast(workspace_id, event, payload) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "workspace:#{workspace_id}",
      {:workspace_update, workspace_id, event, payload}
    )

    :ok
  rescue
    e ->
      Logger.warning("[Session] Broadcast failed for workspace #{workspace_id}: #{Exception.message(e)}")
      :ok
  end

  @doc "PubSub topic for a workspace."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id), do: "workspace:#{workspace_id}"

  # ── GenServer (not used directly — Session module is mostly functional) ────
  # Kept as a start_link stub in case the supervisor tree needs a named process.

  @impl true
  def init(:ok) do
    init_table()
    {:ok, %{}}
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp generate_session_id do
    "sess_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
