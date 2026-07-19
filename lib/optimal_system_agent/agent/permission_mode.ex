defmodule OptimalSystemAgent.Agent.PermissionMode do
  @moduledoc """
  Sticky per-session permission-mode store.

  The TUI's overdrive / Shift+Tab mode toggle sets the mode on the *live* Loop
  GenServer state (`Loop.set_permission_mode/2`). That alone is fragile:

    1. A mode set BEFORE the turn's loop exists races ahead of it — the
       `set_permission_mode` GenServer call returns `{:error, :no_session}` and
       the choice is dropped. When the loop finally starts, `Loop.init` seeds
       `permission_mode` from `Permissions.default_mode/0` (the settings file),
       so the TUI's runtime overdrive is LOST for the actual turn.
    2. A loop (re)created fresh for a session (a new session per turn, or a
       resume) re-reads the settings default — again losing the runtime choice.
    3. A subagent spawned under an overdrive parent inherits nothing and falls
       back to `:ask`, so on its non-interactive `:internal` channel every
       mutating call fails closed.

  This ETS-backed store remembers the last mode chosen for a session id so the
  choice is *sticky*: `Loop.set_permission_mode/2` records it here (even when
  no loop is live yet), and `Loop.init/1` reads it back before falling to the
  settings default. Subagent spawn consults the parent's sticky mode to inherit
  overdrive.

  Lazily-created public ETS table, mirroring `PermissionBroker`.
  """

  @table :osa_session_permission_mode

  # Modes accepted by the sticky store. `:bypass` is normalized to `:overdrive`
  # (its silent alias) so reads return a single canonical value.
  @valid_modes [:ask, :accept_edits, :plan, :overdrive, :bypass, :auto]

  @doc "Remember `mode` as the sticky permission mode for `session_id`."
  @spec put(String.t(), atom()) :: :ok
  def put(session_id, mode) when is_binary(session_id) and mode in @valid_modes do
    ensure_table()
    :ets.insert(@table, {session_id, canonical(mode)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_, _), do: :ok

  @doc "The sticky permission mode for `session_id`, or `nil` when none was set."
  @spec get(String.t()) :: atom() | nil
  def get(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, mode}] -> mode
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def get(_), do: nil

  @doc "True when the session's sticky mode is a full-auto bypass mode."
  @spec overdrive?(String.t()) :: boolean()
  def overdrive?(session_id), do: get(session_id) in [:overdrive, :bypass]

  @doc "Forget the sticky mode for `session_id` (e.g. on session end)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear(_), do: :ok

  defp canonical(:bypass), do: :overdrive
  defp canonical(mode), do: mode

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
