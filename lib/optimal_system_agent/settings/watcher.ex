defmodule OptimalSystemAgent.Settings.Watcher do
  @moduledoc """
  Watches the settings cascade files for EXTERNAL edits.

  Polls every second (the poll interval doubles as the 1s debounce) and, when
  a file's CONTENT HASH changes:

    * resets the settings ETS cache (single reset)
    * re-applies the merged `"env"` key to the OS environment (live)
    * re-validates all sources, logging issues with fix tips
    * emits a `settings_changed` SSE event on the command-center stream and a
      `:system_event` on the internal Bus

  Internal writes (`Settings.set_user/set_project/delete_*`) call
  `note_internal_write/1` BEFORE writing; changes to that path are suppressed
  for 5s so only edits made outside the process (editor, git, another tool)
  fire.

  Deletions get a 1.7s grace window: editors that save via delete+rename
  briefly remove the file — a change only fires if the file is still gone
  after the grace period (or reappears with different content).

  Disabled when `:settings_watcher_enabled` is `false` (the test suite
  changes cwd per test, which would otherwise fire spurious events).

  ## Watch set

  This is a singleton (`name: __MODULE__`), and `Settings.source_paths/0`
  derives its project/local entries from the process-global `Workspace.Cwd`.
  So by default it watches exactly ONE root. OSA also runs under other roots —
  `Agent.Fleet`'s `:working_dir`, the orchestrator's `repo_dir`,
  `Workspace.FastWorktree` worktrees — and settings under those were never
  polled, with no diagnostic: the ETS cache simply kept serving pre-edit values
  while `fire/1`'s `Settings.apply_env_settings/0` left stale `env` vars in the
  BEAM's real OS environment for every subsequent tool call.

  Those callers must therefore `register_root/1` (and `unregister_root/1` when
  the root goes away). `watching/0` and `watching?/1` exist so the gap is
  inspectable rather than silent.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Settings.Schema

  @poll_ms 1_000
  @suppress_ms 5_000
  @delete_grace_ms 1_700

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record an internal write: changes detected on `path` within 5s are ignored."
  def note_internal_write(path) do
    GenServer.cast(__MODULE__, {:internal_write, path})
  catch
    _, _ -> :ok
  end

  @doc """
  Add `root` to the watch set, so `<root>/.osa/settings.json` and
  `.osa/settings.local.json` are polled alongside the process-global cwd
  cascade.

  Anything that runs OSA under a directory other than `Workspace.Cwd` —
  `Agent.Fleet`'s `:working_dir`, the orchestrator's `repo_dir`, a
  `Workspace.FastWorktree` worktree — must call this, otherwise settings under
  that root are read once and then served from the ETS cache forever, including
  any `env` block that `fire/1` pushes into the real OS environment.

  Idempotent, and safe to call when the watcher is disabled or not running.
  """
  @spec register_root(String.t()) :: :ok
  def register_root(root) when is_binary(root) and root != "" do
    GenServer.cast(__MODULE__, {:register_root, Path.expand(root)})
  catch
    _, _ -> :ok
  end

  def register_root(_), do: :ok

  @doc "Remove a root previously added with `register_root/1`."
  @spec unregister_root(String.t()) :: :ok
  def unregister_root(root) when is_binary(root) and root != "" do
    GenServer.cast(__MODULE__, {:unregister_root, Path.expand(root)})
  catch
    _, _ -> :ok
  end

  def unregister_root(_), do: :ok

  @doc """
  The settings files currently being polled.

  Introspection for diagnostics: the failure this exists to make visible is a
  settings file that is being READ but not WATCHED, which otherwise produces no
  log line of any kind. Returns `[]` when the watcher is not running.
  """
  @spec watching() :: [String.t()]
  def watching do
    GenServer.call(__MODULE__, :watching, 1_000)
  catch
    _, _ -> []
  end

  @doc """
  Whether `path` is inside the watch set's coverage.

  `false` means edits to it will NOT be picked up live — call `register_root/1`
  with its project root.
  """
  @spec watching?(String.t()) :: boolean()
  def watching?(path) when is_binary(path), do: Path.expand(path) in watching()
  def watching?(_), do: false

  @impl true
  def init(opts) do
    if Application.get_env(:optimal_system_agent, :settings_watcher_enabled, true) do
      poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
      roots = opts |> Keyword.get(:roots, []) |> Enum.map(&Path.expand/1) |> MapSet.new()

      state = %{
        poll_ms: poll_ms,
        roots: roots,
        sigs: snapshot(MapSet.to_list(roots)),
        internal: %{},
        pending_delete: %{}
      }

      Process.send_after(self(), :poll, poll_ms)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_cast({:internal_write, path}, state) do
    {:noreply, %{state | internal: Map.put(state.internal, path, now_ms())}}
  end

  def handle_cast({:register_root, root}, state) do
    if MapSet.member?(state.roots, root) do
      {:noreply, state}
    else
      roots = MapSet.put(state.roots, root)

      # Seed the new paths' signatures WITHOUT firing: registering a root means
      # "start watching this", not "this just changed".
      sigs =
        Enum.reduce(
          [Path.join(root, ".osa/settings.json"), Path.join(root, ".osa/settings.local.json")],
          state.sigs,
          fn path, acc -> Map.put_new(acc, path, file_sig(path)) end
        )

      Logger.debug("[settings] Watching additional root: #{root}")
      {:noreply, %{state | roots: roots, sigs: sigs}}
    end
  end

  def handle_cast({:unregister_root, root}, state) do
    paths = [Path.join(root, ".osa/settings.json"), Path.join(root, ".osa/settings.local.json")]

    {:noreply,
     %{
       state
       | roots: MapSet.delete(state.roots, root),
         sigs: Map.drop(state.sigs, paths),
         pending_delete: Map.drop(state.pending_delete, paths)
     }}
  end

  @impl true
  def handle_call(:watching, _from, state) do
    {:reply, watched_paths(MapSet.to_list(state.roots)), state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = detect_and_fire(state)
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Detection ───────────────────────────────────────────────────────

  defp detect_and_fire(state) do
    current = snapshot(MapSet.to_list(state.roots))
    now = now_ms()

    {changed, pending} =
      Enum.reduce(current, {[], state.pending_delete}, fn {path, sig}, {changed, pending} ->
        old = Map.get(state.sigs, path)

        cond do
          sig == old ->
            {changed, Map.delete(pending, path)}

          suppressed?(state.internal, path, now) ->
            {changed, Map.delete(pending, path)}

          is_nil(sig) ->
            case Map.get(pending, path) do
              nil -> {changed, Map.put(pending, path, now + @delete_grace_ms)}
              deadline when now >= deadline -> {[path | changed], Map.delete(pending, path)}
              _ -> {changed, pending}
            end

          true ->
            {[path | changed], Map.delete(pending, path)}
        end
      end)

    if changed != [], do: fire(changed)

    sigs =
      Map.new(current, fn {path, sig} ->
        # Paths mid-delete-grace keep their old sig so a reappearing file
        # still diffs against the pre-delete content.
        if Map.has_key?(pending, path),
          do: {path, Map.get(state.sigs, path)},
          else: {path, sig}
      end)

    %{state | sigs: sigs, pending_delete: pending}
  end

  defp suppressed?(internal, path, now) do
    case Map.get(internal, path) do
      nil -> false
      ts -> now - ts <= @suppress_ms
    end
  end

  defp snapshot(extra_roots) do
    watched_paths(extra_roots)
    |> Map.new(fn path -> {path, file_sig(path)} end)
  end

  # The cwd cascade plus every explicitly registered root. `Settings.source_paths/0`
  # derives the project/local entries from the process-global `Workspace.Cwd`,
  # so on its own it only ever describes ONE root.
  defp watched_paths(extra_roots) do
    extra =
      Enum.flat_map(extra_roots, fn root ->
        [
          Path.join(root, ".osa/settings.json"),
          Path.join(root, ".osa/settings.local.json")
        ]
      end)

    (Settings.source_paths() ++ extra) |> Enum.uniq()
  end

  # Change signature for one settings file.
  #
  # This used to be `{mtime, size}`, which never looks at content. `File.stat`
  # mtime has 1-SECOND POSIX granularity and the poll interval is also 1s, so a
  # rewrite that keeps the same size within the same second — a one-character
  # edit, a flag flipped from `true` to `fals`+`e`, `sed -i` on a single value,
  # a git checkout between two same-size revisions — was missed ENTIRELY. A
  # missed reload is not just a stale read: `fire/1` calls
  # `Settings.apply_env_settings/0`, which mutates the BEAM's real OS
  # environment, so stale `env` vars persist for every subsequent tool call.
  #
  # Content hashing removes that blind spot. The files are small and there are
  # a handful of them at a 1s poll, so the cost is irrelevant next to a
  # silently-not-applied permission or env change.
  #
  # FAIL-OPEN: a signature we cannot compute must never SUPPRESS a reload.
  #   * missing file        -> nil, which feeds the existing delete-grace path
  #   * readable            -> content hash
  #   * exists, unreadable  -> degrade to the old {mtime, size} stat signature
  #     (never worse than the previous behaviour) and say so, because a settings
  #     file the agent cannot read is itself worth surfacing
  #   * exists, un-stat-able -> a value that differs every poll, so it reloads
  defp file_sig(path) do
    case File.read(path) do
      {:ok, content} ->
        {:hash, :crypto.hash(:sha256, content)}

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime, size: size}} ->
            Logger.warning(
              "[settings] Cannot read #{path} (#{inspect(reason)}) — falling back to a " <>
                "timestamp/size change check for it. A same-size edit made within the same " <>
                "second will not be detected until the file is readable again."
            )

            {:stat, mtime, size}

          _ ->
            {:indeterminate, System.unique_integer([:positive])}
        end
    end
  end

  # ── Reaction ────────────────────────────────────────────────────────

  defp fire(paths) do
    Settings.reset_cache()
    Settings.apply_env_settings()
    issues = Schema.validate_and_log()

    payload = %{paths: paths, issue_count: length(issues), source: "external_edit"}

    OptimalSystemAgent.EventStream.broadcast("settings_changed", payload)

    OptimalSystemAgent.Events.Bus.emit(
      :system_event,
      Map.put(payload, :event, :settings_changed)
    )

    Logger.info("[settings] Reloaded after external edit: #{Enum.join(paths, ", ")}")
  rescue
    e -> Logger.warning("[settings] Change handling failed: #{Exception.message(e)}")
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
