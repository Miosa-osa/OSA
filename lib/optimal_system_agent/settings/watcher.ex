defmodule OptimalSystemAgent.Settings.Watcher do
  @moduledoc """
  Watches the settings cascade files for EXTERNAL edits.

  Polls every second (the poll interval doubles as the 1s debounce) and, when
  a file's `{mtime, size}` signature changes:

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

  @impl true
  def init(opts) do
    if Application.get_env(:optimal_system_agent, :settings_watcher_enabled, true) do
      poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
      state = %{poll_ms: poll_ms, sigs: snapshot(), internal: %{}, pending_delete: %{}}
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

  @impl true
  def handle_info(:poll, state) do
    state = detect_and_fire(state)
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Detection ───────────────────────────────────────────────────────

  defp detect_and_fire(state) do
    current = snapshot()
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

  defp snapshot do
    Settings.source_paths()
    |> Enum.uniq()
    |> Map.new(fn path -> {path, file_sig(path)} end)
  end

  defp file_sig(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _ -> nil
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
