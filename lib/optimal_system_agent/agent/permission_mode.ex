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

  Lazily-created public ETS table, mirroring `PermissionBroker`. The ETS table is
  ALSO backed by a small on-disk JSON file (`~/.osa/permission_mode.json`), so the
  chosen mode survives a daemon restart — otherwise an operator who turned on
  overdrive would silently drop back to `:ask` the next time the backend bounced,
  while the TUI kept showing "overdrive on". The disk file is loaded into ETS the
  first time the table is created (post-restart) and rewritten on every put/clear.
  """

  alias OptimalSystemAgent.System.AtomicFile

  @table :osa_session_permission_mode

  # Modes accepted by the sticky store. `:bypass` is normalized to `:overdrive`
  # (its silent alias) so reads return a single canonical value.
  @valid_modes [:ask, :accept_edits, :plan, :overdrive, :bypass, :auto]

  @doc "Remember `mode` as the sticky permission mode for `session_id`."
  @spec put(String.t(), atom()) :: :ok
  def put(session_id, mode) when is_binary(session_id) and mode in @valid_modes do
    ensure_table()
    :ets.insert(@table, {session_id, canonical(mode)})
    persist_to_disk()
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
    persist_to_disk()
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
        # First creation after a (re)start: rehydrate from disk so overdrive and
        # other sticky modes survive a daemon bounce.
        load_from_disk()
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ── Disk persistence (~/.osa/permission_mode.json) ─────────────────────

  defp disk_path do
    # An explicit app-env override wins (test isolation — mirrors
    # :permissions_file / :durable_log_dir). Without it the sticky store lived at
    # the real ~/.osa/permission_mode.json even under `mix test`, so test session
    # ids ("mode-38", …) persisted "overdrive" to the SAME file the live daemon
    # reads, and recycled unique() ids across runs collided into false
    # non-:ask defaults. Isolating the path keeps test writes out of the real
    # store entirely.
    case Application.get_env(:optimal_system_agent, :permission_mode_file) do
      path when is_binary(path) ->
        path

      _ ->
        base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
        Path.join(base, "permission_mode.json")
    end
  end

  # Dump the whole ETS table to disk atomically (temp + rename). Best-effort:
  # a persistence failure must never break a permission decision.
  defp persist_to_disk do
    path = disk_path()

    map =
      :ets.tab2list(@table)
      |> Map.new(fn {sid, mode} -> {sid, Atom.to_string(mode)} end)

    File.mkdir_p(Path.dirname(path))
    AtomicFile.write!(path, Jason.encode!(map))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Load persisted modes into ETS (called once on table creation). Unknown /
  # malformed entries are skipped; a missing file is fine (empty store).
  defp load_from_disk do
    with {:ok, body} <- File.read(disk_path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      for {sid, mode_str} <- map, is_binary(sid), is_binary(mode_str) do
        mode = safe_to_mode(mode_str)
        if mode, do: :ets.insert(@table, {sid, mode})
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_to_mode(str) do
    mode = String.to_existing_atom(str)
    if mode in @valid_modes, do: canonical(mode), else: nil
  rescue
    ArgumentError -> nil
  end
end
