defmodule OptimalSystemAgent.Prefetch.Cache do
  @moduledoc """
  Bounded, TTL'd store of speculatively-fetched read-only tool results.

  A hit here means `Agent.Loop.ToolExecutor` skips the real tool dispatch
  entirely and hands the model the body `Prefetch.Engine` already fetched in
  the background while the previous turn was still streaming.

  ## Keys

  `fingerprint/2` strips the loop's injected `__session_id__` / `__tool_use_id__`
  / `__delegation_depth__` / `__surface__` keys before hashing, so the SAME
  `file_read("/a/b.ex")` fires a hit regardless of which turn or session asks
  for it — the file's content does not depend on either.

  ## Freshness — filesystem truth, not bookkeeping

  A file changes for reasons OSA's own tools never see: the user's editor, a
  formatter, `git checkout`/`git pull`, a build step, another process
  entirely. Tracking only the writes that went through OSA's own tools (an
  earlier version of this module did exactly that) is provably incomplete —
  it can only ever catch a subset of "this content is no longer on disk".

  So freshness here is checked against the filesystem itself, every time,
  cheaply:

    * `stat_snapshot/1` — `File.stat/1`'s `{mtime, size, inode}` triple for a
      path. `Prefetch.Engine` takes ONE of these immediately before reading
      the file/dir and ANOTHER immediately after; only if they are IDENTICAL
      does it know the content it just read corresponds to that exact
      filesystem state, and only then does it call `put/5`. A mismatch there
      means the file changed WHILE it was being read — discarded, never
      cached, regardless of what wrote it.
    * `get/1` re-`stat`s the watched path on every lookup and compares
      against the triple recorded at store time. Any difference — including
      the path no longer existing — is a miss, and the stale row is dropped
      on the spot. This is what catches the case `put/5`'s own check cannot:
      a change that lands strictly AFTER the entry was stored, from any
      source, internal or external.
    * a plain wall-clock TTL (`ttl_ms/0`) still bounds the worst case (an
      inode reused by the filesystem with coincidentally identical size, on a
      platform/filesystem where that is possible) — belt and suspenders, not
      the primary mechanism.

  ### The racy-mtime gap, and why `put/5` refuses a "too fresh" file

  Erlang's `File.stat/2` reports `mtime` with WHOLE-SECOND granularity (a
  POSIX-time integer), not the sub-second precision the underlying filesystem
  usually has. Two writes to the same path within the same second can
  therefore leave `mtime` identical across both — and if the second write
  happens to produce the same byte size too (an in-place rewrite reuses the
  inode), the entire `{mtime, size, inode}` triple is indistinguishable from
  "nothing changed", permanently: the file's mtime never advances past that
  second, so no LATER check can detect the collision either.

  `put/5` closes this the same way a build tool's own "racily clean" guard
  does: it refuses to cache a file whose `mtime` is still within the current
  wall-clock second (`settled?/1`) — not enough time has passed to be sure a
  second write did not land invisibly in the same tick. Once a file's mtime
  is more than a second old, any FUTURE write is guaranteed to bump it to a
  new value, which the ordinary stat comparison then catches. The cost is
  only ever a missed prefetch opportunity for a file edited in the last
  second — never a false "fresh".

  `invalidate_path/1` and `invalidate_all/0` are a proactive OPTIMIZATION on
  top of this, not a correctness requirement: dropping a row the instant OSA's
  own tool writes it avoids a wasted hit-then-discover-stale round trip, but
  even if they were never called, the `stat` check on `get/1` still catches
  it.

  ## Eviction

  Row count capped via `Infra.BoundedTable` (oldest-inserted evicted first).
  Bounded IO/memory: a runaway speculation cannot grow this without limit.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Safety.PathCanon
  alias OptimalSystemAgent.Infra.BoundedTable

  @cache_table :osa_prefetch_cache

  @max_rows 200
  @default_ttl_ms 30_000
  @default_settle_seconds 1

  @enforce_keys [:result, :watch, :stat, :duration_ms, :inserted_at]
  defstruct [:result, :watch, :stat, :duration_ms, :inserted_at]

  @typedoc "The single path this entry's freshness is checked against."
  @type watch :: {:path, String.t()}

  @typedoc "`File.stat/1`'s identity triple for a path at a point in time."
  @type stat :: %{mtime: term(), size: non_neg_integer(), inode: term()}

  @type t :: %__MODULE__{
          result: String.t(),
          watch: watch(),
          stat: stat(),
          duration_ms: non_neg_integer(),
          inserted_at: integer()
        }

  @doc "Create the ETS table this module owns. Idempotent, never raises."
  @spec init_tables() :: :ok
  def init_tables do
    new_table(@cache_table)
    :ok
  end

  @doc """
  Drop every cached entry. For session-end/`/clear` cleanup and for tests
  that need a clean slate.
  """
  @spec reset!() :: :ok
  def reset! do
    ensure_tables()
    :ets.delete_all_objects(@cache_table)
    :ok
  rescue
    _ -> :ok
  end

  defp new_table(name) do
    :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Stable cache key for `tool_name` + `args`, order-independent and blind to the
  loop's per-call injected keys.
  """
  @spec fingerprint(String.t(), map()) :: term()
  def fingerprint(tool_name, args) when is_binary(tool_name) and is_map(args) do
    relevant =
      args
      |> Map.drop(["__session_id__", "__tool_use_id__", "__delegation_depth__", "__surface__"])
      |> stringify_keys()

    {tool_name, relevant}
  end

  defp stringify_keys(map) when is_map(map) do
    map |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end) |> Enum.sort()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  @doc """
  `{mtime, size, inode}` for `path`, or `nil` if it cannot be stat'd (does not
  exist, permission denied, transient FS error). Never raises.
  """
  @spec stat_snapshot(String.t()) :: stat() | nil
  def stat_snapshot(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size, inode: inode}} ->
        %{mtime: mtime, size: size, inode: inode}

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  def stat_snapshot(_), do: nil

  @doc """
  Look up `key`. A hit is only ever returned when the watched path's CURRENT
  `stat_snapshot/1` is byte-identical to the one recorded at store time —
  otherwise the row is dropped and this reports `:miss`, exactly like the
  content was never cached at all.
  """
  @spec get(term()) :: {:hit, String.t(), non_neg_integer()} | :miss
  def get(key) do
    ensure_tables()

    case :ets.lookup(@cache_table, key) do
      [{^key, %__MODULE__{} = entry}] ->
        if fresh_ttl?(entry.inserted_at) and fresh_on_disk?(entry) do
          {:hit, entry.result, entry.duration_ms}
        else
          delete(key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Store `result` under `key`, watched by `watch`, stamped with `stat` — the
  `stat_snapshot/1` the caller took at the moment it read `result` (see the
  moduledoc for the pre/post-read protocol this depends on). Refuses to store
  (returns `:stale`) when either:

    * a FRESH snapshot no longer matches `stat` — a last-instant guard on the
      read-to-store window itself, or
    * `stat`'s mtime is not yet "settled" (see the moduledoc's racy-mtime
      section) — caching it now could not be told apart from caching a
      collision that has not happened yet.
  """
  @spec put(term(), String.t(), watch(), stat(), non_neg_integer()) :: :ok | :stale
  def put(key, result, {:path, path} = watch, stat, duration_ms) do
    ensure_tables()

    if settled?(stat) and stat_snapshot(path) == stat do
      entry = %__MODULE__{
        result: result,
        watch: watch,
        stat: stat,
        duration_ms: duration_ms,
        inserted_at: System.monotonic_time(:millisecond)
      }

      BoundedTable.insert(@cache_table, key, entry, max: @max_rows)
      :ok
    else
      :stale
    end
  rescue
    _ -> :stale
  end

  @doc "Delete `key`, if present."
  @spec delete(term()) :: :ok
  def delete(key) do
    BoundedTable.delete(@cache_table, key)
    :ok
  end

  @doc """
  A write just landed on `path`. Proactively drops every cache row watching
  this exact path — an optimization (see moduledoc), not a correctness
  requirement.
  """
  @spec invalidate_path(String.t()) :: :ok
  def invalidate_path(path) when is_binary(path) do
    ensure_tables()
    canon = canon(path)

    @cache_table
    |> safe_tab2list()
    |> Enum.each(fn {key, %__MODULE__{watch: watch}} ->
      if watches?(watch, canon), do: delete(key)
    end)

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  A write happened whose scope could not be pinned to a specific path (an
  unclassified write tool, or a shell command that was not provably
  read-only). Conservative: drops every cached entry.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    ensure_tables()
    @cache_table |> safe_tab2list() |> Enum.each(fn {key, _} -> delete(key) end)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Path watch for a single file/dir, for `file_read`/`dir_list`-shaped prefetches."
  @spec path_watch(String.t()) :: watch()
  def path_watch(path) when is_binary(path), do: {:path, canon(path)}

  # ── Private ────────────────────────────────────────────────────────────

  defp watches?({:path, p}, canon), do: p == canon
  defp watches?(_watch, _canon), do: false

  defp fresh_on_disk?(%__MODULE__{watch: {:path, path}, stat: stat}) do
    stat_snapshot(path) == stat
  end

  defp fresh_on_disk?(_entry), do: false

  defp fresh_ttl?(inserted_at), do: System.monotonic_time(:millisecond) - inserted_at < ttl_ms()

  # Overridable so tests can shrink the window instead of sleeping 30s.
  defp ttl_ms,
    do: Application.get_env(:optimal_system_agent, :prefetch_cache_ttl_ms, @default_ttl_ms)

  # See the moduledoc's "racy-mtime gap" section. `mtime` is POSIX whole
  # seconds; comparing against wall-clock `System.os_time(:second)` (not
  # monotonic time, which has no relationship to POSIX time) is what makes
  # this comparable at all.
  defp settled?(%{mtime: mtime}) when is_integer(mtime) do
    System.os_time(:second) - mtime >= settle_seconds()
  end

  defp settled?(_stat), do: false

  defp settle_seconds,
    do:
      Application.get_env(
        :optimal_system_agent,
        :prefetch_settle_seconds,
        @default_settle_seconds
      )

  defp canon(path), do: PathCanon.canonicalize(path)

  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    _ -> []
  end

  defp ensure_tables do
    if :ets.whereis(@cache_table) == :undefined, do: init_tables()
  rescue
    _ -> :ok
  end
end
