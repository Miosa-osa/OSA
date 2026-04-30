defmodule OptimalSystemAgent.FSCheckpoint.Server do
  @moduledoc """
  GenServer that manages the shadow git repo used for filesystem checkpoints.

  The shadow repo lives at `~/.osa/fs_checkpoints/`. Before any destructive
  file operation the pre_tool_use hook calls `snapshot/3`, which copies the
  affected files into the shadow repo and creates a git commit. The commit
  message encodes the tool name, session id, and affected paths so they can
  be displayed in `list_checkpoints/1` without extra parsing.

  Restore works by re-copying files from the shadow commit back to their
  original absolute paths. It does NOT use `git checkout` against the working
  tree to avoid any accidental interaction with the host project's git history.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.FSCheckpoint.Config

  # ── Client API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec snapshot(String.t(), String.t(), [String.t()]) :: :ok
  def snapshot(session_id, tool_name, paths) when is_list(paths) do
    if Config.enabled?() do
      GenServer.cast(__MODULE__, {:snapshot, session_id, tool_name, paths})
    end

    :ok
  end

  @spec list_checkpoints(pos_integer()) :: {:ok, [map()]} | {:error, String.t()}
  def list_checkpoints(limit \\ 20) do
    GenServer.call(__MODULE__, {:list, limit})
  end

  @spec restore(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def restore(checkpoint_id) do
    GenServer.call(__MODULE__, {:restore, checkpoint_id}, 30_000)
  end

  @spec diff(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(checkpoint_id) do
    GenServer.call(__MODULE__, {:diff, checkpoint_id})
  end

  # ── Server callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Self-register the pre_tool_use hook so the server owns its own wiring.
    # This avoids touching hooks.ex and keeps the feature fully self-contained.
    OptimalSystemAgent.Agent.Hooks.register(
      :pre_tool_use,
      "fs_checkpoint",
      &OptimalSystemAgent.FSCheckpoint.Hook.pre_tool_use/1,
      priority: 11
    )

    repo = Config.repo_path()
    ensure_shadow_repo(repo)
    {:ok, %{repo_path: repo}}
  end

  @impl true
  def handle_cast({:snapshot, session_id, tool_name, paths}, state) do
    try do
      do_snapshot(state.repo_path, session_id, tool_name, paths)
    rescue
      e -> Logger.warning("[fs_checkpoint] Snapshot failed: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:list, limit}, _from, state) do
    result = do_list(state.repo_path, limit)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:restore, checkpoint_id}, _from, state) do
    result = do_restore(state.repo_path, checkpoint_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:diff, checkpoint_id}, _from, state) do
    result = do_diff(state.repo_path, checkpoint_id)
    {:reply, result, state}
  end

  # ── Private: repo management ──────────────────────────────────────────

  defp ensure_shadow_repo(repo_path) do
    File.mkdir_p!(repo_path)
    git_dir = Path.join(repo_path, ".git")

    unless File.dir?(git_dir) do
      {_, 0} = System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.name=OSA Checkpoint",
            "-c",
            "user.email=checkpoint@osa",
            "commit",
            "--allow-empty",
            "-m",
            "init"
          ],
          cd: repo_path,
          stderr_to_stdout: true
        )

      Logger.info("[fs_checkpoint] Shadow repo initialized at #{repo_path}")
    end
  end

  # ── Private: snapshot ─────────────────────────────────────────────────

  defp do_snapshot(repo_path, session_id, tool_name, paths) do
    copied =
      paths
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn path ->
        case File.stat(path) do
          {:ok, %{size: size}} -> size <= Config.max_file_size()
          _ -> false
        end
      end)
      |> Enum.map(fn original_path ->
        # Store under the absolute path structure inside the shadow repo so
        # restore can reconstruct the original location without metadata.
        dest = Path.join(repo_path, original_path)
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(original_path, dest)
        original_path
      end)

    if copied != [] do
      {_, 0} = System.cmd("git", ["add", "-A"], cd: repo_path, stderr_to_stdout: true)

      commit_msg = "#{tool_name} | #{session_id} | #{Enum.join(copied, ", ")}"

      {_, _} =
        System.cmd(
          "git",
          [
            "-c",
            "user.name=OSA Checkpoint",
            "-c",
            "user.email=checkpoint@osa",
            "commit",
            "-m",
            commit_msg
          ],
          cd: repo_path,
          stderr_to_stdout: true
        )

      maybe_prune(repo_path)
      Logger.debug("[fs_checkpoint] Snapshot: #{length(copied)} file(s) for #{tool_name}")
    end
  end

  # ── Private: list ─────────────────────────────────────────────────────

  defp do_list(repo_path, limit) do
    case System.cmd("git", ["log", "--format=%H|%s|%ci", "-#{limit}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        entries =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.ends_with?(&1, "|init|"))
          |> Enum.reject(fn line ->
            case String.split(line, "|", parts: 3) do
              [_, "init", _] -> true
              _ -> false
            end
          end)
          |> Enum.map(&parse_log_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {err, _} ->
        {:error, "Failed to list checkpoints: #{err}"}
    end
  end

  defp parse_log_line(line) do
    case String.split(line, "|", parts: 3) do
      [hash, subject, date] ->
        parts = String.split(subject, " | ", parts: 3)

        %{
          id: String.slice(hash, 0, 8),
          full_id: hash,
          tool: List.first(parts) || subject,
          files: List.last(parts) || "",
          date: String.trim(date)
        }

      _ ->
        nil
    end
  end

  # ── Private: restore ──────────────────────────────────────────────────

  defp do_restore(repo_path, checkpoint_id) do
    case System.cmd("git", ["rev-parse", checkpoint_id],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {full_hash, 0} ->
        full_hash = String.trim(full_hash)
        restore_files_from_commit(repo_path, full_hash)

      {_, _} ->
        {:error, "Checkpoint '#{checkpoint_id}' not found"}
    end
  end

  defp restore_files_from_commit(repo_path, full_hash) do
    case System.cmd(
           "git",
           ["diff-tree", "--no-commit-id", "-r", "--name-only", full_hash],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {files_output, 0} ->
        files = files_output |> String.trim() |> String.split("\n", trim: true)

        restored =
          files
          |> Enum.map(fn file_in_repo ->
            source = Path.join(repo_path, file_in_repo)
            # file_in_repo is the absolute path stored without leading slash
            target = "/" <> file_in_repo

            if File.regular?(source) do
              File.mkdir_p!(Path.dirname(target))
              File.cp!(source, target)
              target
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, "Restored #{length(restored)} file(s): #{Enum.join(restored, ", ")}"}

      {err, _} ->
        {:error, "Failed to read checkpoint files: #{err}"}
    end
  end

  # ── Private: diff ─────────────────────────────────────────────────────

  defp do_diff(repo_path, checkpoint_id) do
    case System.cmd("git", ["show", "--stat", "--patch", checkpoint_id],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {err, _} -> {:error, "Failed to show diff: #{err}"}
    end
  end

  # ── Private: pruning ──────────────────────────────────────────────────

  defp maybe_prune(repo_path) do
    max = Config.max_checkpoints()

    case System.cmd("git", ["rev-list", "--count", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {count_str, 0} ->
        count = count_str |> String.trim() |> String.to_integer()

        if count > max + 10 do
          Logger.info("[fs_checkpoint] Checkpoint count #{count} exceeds max #{max} — consider pruning the shadow repo at #{repo_path}")
        end

      _ ->
        :ok
    end
  end
end
