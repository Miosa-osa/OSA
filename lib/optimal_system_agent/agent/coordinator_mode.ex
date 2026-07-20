defmodule OptimalSystemAgent.Agent.CoordinatorMode do
  @moduledoc """
  Sticky per-session coordinator-mode store.

  Coordinator mode restricts a session's tool surface to delegation, messaging,
  and management tools only (see `Agent.Loop.ToolFilter.filter_for_coordinator/2`
  and the `@coordinator_tools` allowlist). The TUI toggles it at runtime via
  `Loop.set_coordinator/2`, but that alone is fragile in exactly the ways the
  permission-mode toggle was (see `Agent.PermissionMode`):

    1. A toggle set BEFORE the turn's loop exists races ahead of it: the
       `set_coordinator` GenServer call exits with `:no_session` and the choice
       is dropped. When the loop finally starts, `Loop.init/1` would seed
       `coordinator` from the opts default (false), losing the runtime choice.
    2. A loop (re)created fresh for a session (a new session per turn, or a
       resume) re-reads that default and again loses the runtime choice.

  This ETS-backed store remembers the last coordinator flag chosen for a session
  id so the choice is *sticky*: `Loop.set_coordinator/2` records it here (even
  when no loop is live yet), and `Loop.init/1` reads it back before falling to
  the opts default. Unlike `PermissionMode`, coordinator mode is NOT persisted to
  disk: a daemon restart clears the table, both the resumed loop and the TUI's
  reconnect-time status query then resolve to the default (off), so the two stay
  consistent (no "coordinator on" lie survives a restart).

  Lazily-created public ETS table, mirroring `PermissionMode`.
  """

  @table :osa_session_coordinator_mode

  @doc "Remember `on?` as the sticky coordinator flag for `session_id`."
  @spec put(String.t(), boolean()) :: :ok
  def put(session_id, on?) when is_binary(session_id) and is_boolean(on?) do
    ensure_table()
    :ets.insert(@table, {session_id, on?})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_, _), do: :ok

  @doc "The sticky coordinator flag for `session_id` (defaults to false)."
  @spec get(String.t()) :: boolean()
  def get(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, on?}] -> on?
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def get(_), do: false

  @doc "Forget the sticky flag for `session_id` (e.g. on session end)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear(_), do: :ok

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
