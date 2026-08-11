defmodule OptimalSystemAgent.Agent.Fleet.SettingsCoverage do
  @moduledoc """
  Says out loud when work is about to run under a root whose `.osa/settings.json`
  will not be honoured.

  ## Why this is a diagnostic and not a `Watcher.register_root/1` call

  `Settings.Watcher` grew `register_root/1` so alternate roots could be polled.
  Wiring the callers to it would not have closed the gap, and would have
  replaced silence with a confident, wrong log line. The settings layer is
  cwd-derived end to end:

    * `Settings.project_settings_path/0` and `local_settings_path/0` are
      `Path.join(Workspace.Cwd.get(), ".osa/settings.json")` — the
      process-global cwd, never the caller's root.
    * `Settings.reset_cache/0` is `:ets.delete_all_objects/1` on ONE global
      table. There is no per-root cache entry to invalidate.
    * `Settings.apply_env_settings/0` applies `merged_trusted()`, whose trust
      gate is `Workspace.Trust.trusted?(Workspace.Cwd.get())`.

  So under an alternate root, `Settings` never READS that root's files at all.
  The cache is not serving pre-edit values for it — it holds no values for it,
  ever. Registering the root would make the watcher poll two files whose
  contents feed nothing, and on a change fire a global `reset_cache/0` plus a
  re-apply of the CWD's env, then log `"Reloaded after external edit:
  <worktree>/.osa/settings.json"` — naming a file whose contents were never
  applied to anything. A watcher that reports success for work it did not do is
  worse than one that is silent.

  There is a second reason to stop short. `apply_env_settings/0` mutates the
  BEAM's real OS environment, and the trust gate is evaluated against the cwd,
  not against the registered root. Auto-registering a caller-supplied
  `:working_dir` would let an arbitrary directory's settings file act as the
  trigger for a global env re-apply, with that directory itself never trust-
  evaluated. Fan-out `:working_dir` values are caller-supplied.

  The genuine fix is per-root settings resolution inside `Settings` — a
  `source_paths/1` that takes a root, a cache keyed by root, and an
  `apply_env_settings/1` scoped to it. That is `settings*`, another lane's
  files. Until it exists, this module makes the gap loud instead of invisible,
  which is what a caller can honestly do from here.

  ## Behaviour

  `check/2` is called wherever a run adopts a working directory other than the
  cwd cascade root. It logs once per root, and only when there is something to
  report: a settings file that actually exists under that root and is not
  covered by `Settings.Watcher.watching?/1`. A root with no settings file, or
  one the watcher already covers, is silent.

  Placement note: this lives under `agent/fleet/` because that is a directory
  this lane owns; `settings/**` is not. It is not fleet-specific.
  """

  require Logger

  alias OptimalSystemAgent.Settings.Watcher

  # Bound on the "already reported" memo, so a long session that cycles through
  # many worktrees cannot grow it without limit. Past the bound the table is
  # cleared and roots may be reported a second time — a repeated diagnostic is
  # an acceptable price for a bounded table.
  @max_reported 512

  @table :osa_settings_coverage_reported

  @doc """
  Report an alternate working root that carries settings nothing will honour.

  `context` names the caller (e.g. `"fleet node"`, `"subagent worktree"`) so
  the log line says which subsystem adopted the root. Never raises, never
  returns anything but `:ok` — a diagnostic must not be able to break the run
  it is describing.
  """
  @spec check(String.t() | nil, String.t()) :: :ok
  def check(root, context) when is_binary(root) and root != "" and is_binary(context) do
    expanded = Path.expand(root)

    if expanded == cwd_root() do
      :ok
    else
      expanded
      |> unwatched_settings_files()
      |> report(expanded, context)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def check(_root, _context), do: :ok

  @doc """
  Settings files that exist under `root` but are not covered by the watcher.

  Public so the gap is inspectable — the whole failure mode is that it is
  currently invisible.
  """
  @spec unwatched_settings_files(String.t()) :: [String.t()]
  def unwatched_settings_files(root) when is_binary(root) do
    root
    |> settings_paths()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&watched?/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "The two settings paths a root would contribute."
  @spec settings_paths(String.t()) :: [String.t()]
  def settings_paths(root) when is_binary(root) do
    [
      Path.join(root, ".osa/settings.json"),
      Path.join(root, ".osa/settings.local.json")
    ]
  end

  @doc "Forget which roots have already been reported (tests)."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp report([], _root, _context), do: :ok

  defp report(files, root, context) do
    if first_report?(root) do
      Logger.warning(
        "[settings] #{context} is running under #{root}, but " <>
          "#{Enum.join(files, ", ")} will NOT be applied or reloaded. Settings resolve " <>
          "against the process-global working directory (#{cwd_root()}), so this file is " <>
          "never read, and edits to it take effect nowhere. Move the settings to that root, " <>
          "or run OSA with this directory as its working directory."
      )
    end

    :ok
  end

  # A root is reported once. Without this a 50-node fan-out under one repo
  # would emit the same warning 50 times and bury it.
  defp first_report?(root) do
    ensure_table()

    if :ets.info(@table, :size) >= @max_reported do
      :ets.delete_all_objects(@table)
    end

    :ets.insert_new(@table, {root, true})
  rescue
    # Cannot memoize — report rather than swallow. A duplicated warning is
    # recoverable; a dropped one is the bug this module exists for.
    _ -> true
  end

  defp watched?(path) do
    Watcher.watching?(path)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp cwd_root do
    Path.expand(OptimalSystemAgent.Workspace.Cwd.get())
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
