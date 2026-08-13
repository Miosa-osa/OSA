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

  # ── Retention ─────────────────────────────────────────────────────────
  #
  # Rows are keyed by session id and nothing ever ends a session, so without a
  # bound both the ETS table and `~/.osa/permission_mode.json` grow by one entry
  # per session forever — the file is rewritten in full on every mode change, so
  # the cost is paid on every toggle, not just at read.
  #
  # Two independent bounds, applied on write and on load:
  #   * age  — a session id nobody has touched in 30 days is dead. Its sticky
  #            mode is worthless (a resumed session re-asserts its mode).
  #   * count— a hard ceiling so a burst of short-lived sessions (benchmarks,
  #            subagents) cannot blow the file up inside the age window. The
  #            most recently updated entries survive.
  @max_age_ms 30 * 24 * 60 * 60 * 1000
  @max_entries 500

  @doc "Remember `mode` as the sticky permission mode for `session_id`."
  @spec put(String.t(), atom()) :: :ok
  def put(session_id, mode) when is_binary(session_id) and mode in @valid_modes do
    ensure_table()
    :ets.insert(@table, {session_id, canonical(mode), now_ms()})
    evict()
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
      [{^session_id, mode, _updated_at}] -> mode
      # Tolerated for a row written by an older build still resident in ETS.
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

  @doc """
  Number of sticky entries currently held (tests / diagnostics).
  """
  @spec size() :: non_neg_integer()
  def size do
    ensure_table()
    :ets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  defp canonical(:bypass), do: :overdrive
  defp canonical(mode), do: mode

  defp now_ms, do: System.system_time(:millisecond)

  # Drop expired rows, then trim to @max_entries most-recently-updated.
  defp evict do
    cutoff = now_ms() - @max_age_ms

    # `:ets.select_delete` over the timestamp field: one pass, no intermediate
    # list of the whole table.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    if (:ets.info(@table, :size) || 0) > @max_entries do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(
        fn
          {_sid, _mode, ts} -> ts
          _ -> 0
        end,
        :desc
      )
      |> Enum.drop(@max_entries)
      |> Enum.each(fn row -> :ets.delete(@table, elem(row, 0)) end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

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

    # Value shape: %{"mode" => ..., "updated_at" => ms}. The timestamp has to
    # survive a restart or the age bound silently resets on every daemon bounce
    # and never evicts anything. A bare string is still accepted on read (files
    # written by older builds).
    map =
      :ets.tab2list(@table)
      |> Map.new(fn
        {sid, mode, updated_at} ->
          {sid, %{"mode" => Atom.to_string(mode), "updated_at" => updated_at}}

        {sid, mode} ->
          {sid, %{"mode" => Atom.to_string(mode), "updated_at" => now_ms()}}
      end)

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
      for {sid, entry} <- map, is_binary(sid) do
        {mode_str, updated_at} = decode_entry(entry)
        mode = if is_binary(mode_str), do: safe_to_mode(mode_str)
        if mode, do: :ets.insert(@table, {sid, mode, updated_at})
      end

      # The bounds are applied on LOAD as well as on write: a file that grew
      # unbounded under an older build is trimmed the first time this build
      # reads it, instead of being carried forward forever.
      evict()
      persist_to_disk()
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Accepts both the current `%{"mode" => m, "updated_at" => ms}` shape and the
  # bare `"mode"` string written by builds before retention existed. An entry
  # with no timestamp is treated as written NOW rather than as ancient: dropping
  # every pre-existing sticky mode on upgrade would silently turn overdrive off.
  defp decode_entry(%{"mode" => mode} = entry) when is_binary(mode) do
    case Map.get(entry, "updated_at") do
      ts when is_integer(ts) -> {mode, ts}
      _ -> {mode, now_ms()}
    end
  end

  defp decode_entry(mode) when is_binary(mode), do: {mode, now_ms()}
  defp decode_entry(_), do: {nil, now_ms()}

  defp safe_to_mode(str) do
    mode = String.to_existing_atom(str)
    if mode in @valid_modes, do: canonical(mode), else: nil
  rescue
    ArgumentError -> nil
  end
end
