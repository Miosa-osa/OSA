defmodule OptimalSystemAgent.Verification.Checkpoint do
  @moduledoc """
  State persistence for verification loops.

  Saves verification loop state to disk as JSON so that progress survives
  process crashes or restarts. Each loop gets its own file keyed by loop_id.

  Storage: `~/.osa/verification_checkpoints/{loop_id}.json`
  """
  require Logger

  @doc "Base directory for verification checkpoints."
  @spec checkpoint_dir() :: String.t()
  def checkpoint_dir do
    Application.get_env(
      :optimal_system_agent,
      :verification_checkpoint_dir,
      "~/.osa/verification_checkpoints"
    )
    |> Path.expand()
  end

  @doc """
  Full path to the checkpoint file for `loop_id`.

  `loop_id` reaches here from tool input (`verify_loop` accepts a caller-chosen
  `task_id`, and a loop can be started with an explicit `:loop_id`), so it is
  sanitised before it becomes a filename: without that, an id like
  `"../../.ssh/authorized_keys"` made `save/2` write, and `delete/1` `File.rm`,
  an arbitrary path outside `checkpoint_dir/0`. Same replacement
  `Agent.SessionPersistence` uses for session ids.
  """
  @spec checkpoint_path(String.t()) :: String.t()
  def checkpoint_path(loop_id) do
    Path.join(checkpoint_dir(), "#{safe_id(loop_id)}.json")
  end

  @doc false
  @spec safe_id(String.t()) :: String.t()
  def safe_id(loop_id) do
    Regex.replace(~r/[^a-zA-Z0-9_\-]/, to_string(loop_id), "_")
  end

  @doc """
  Persist verification loop state to disk.

  `state` is a plain map; all values must be JSON-serializable. Atom keys are
  converted to strings for portability.

  Returns `:ok` on success or `{:error, reason}` on failure (write errors are
  also logged as warnings so the loop can continue without crashing).
  """
  @spec save(String.t(), map()) :: :ok | {:error, term()}
  def save(loop_id, state) when is_binary(loop_id) and is_map(state) do
    dir = checkpoint_dir()
    File.mkdir_p!(dir)

    path = checkpoint_path(loop_id)

    payload =
      state
      |> stringify_keys()
      |> Map.put("loop_id", loop_id)
      |> Map.put("checkpointed_at", DateTime.utc_now() |> DateTime.to_iso8601())

    case Jason.encode(payload) do
      {:ok, json} ->
        case File.write(path, json, [:utf8]) do
          :ok ->
            Logger.debug("[Verification.Checkpoint] Saved #{loop_id} at #{path}")
            prune()
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Verification.Checkpoint] Write failed for #{loop_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning(
          "[Verification.Checkpoint] JSON encode failed for #{loop_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning(
        "[Verification.Checkpoint] Unexpected error saving #{loop_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  @doc """
  Restore a previously saved verification loop state.

  Returns `{:ok, state_map}` or `{:ok, nil}` when no checkpoint exists.
  Returns `{:error, reason}` on read/decode failure.
  """
  @spec restore(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def restore(loop_id) when is_binary(loop_id) do
    path = checkpoint_path(loop_id)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, state} ->
              Logger.debug("[Verification.Checkpoint] Restored #{loop_id} from #{path}")
              {:ok, state}

            {:error, reason} ->
              Logger.warning(
                "[Verification.Checkpoint] JSON decode failed for #{loop_id}: #{inspect(reason)}"
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.warning(
            "[Verification.Checkpoint] Read failed for #{loop_id}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      {:ok, nil}
    end
  rescue
    e ->
      Logger.warning(
        "[Verification.Checkpoint] Unexpected error restoring #{loop_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  @doc "Delete a checkpoint file. Silently ignores missing files."
  @spec delete(String.t()) :: :ok
  def delete(loop_id) when is_binary(loop_id) do
    path = checkpoint_path(loop_id)

    case File.rm(path) do
      :ok ->
        Logger.debug("[Verification.Checkpoint] Deleted checkpoint for #{loop_id}")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Verification.Checkpoint] Delete failed for #{loop_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # --- Private ---

  # Retention cap for `~/.osa/verification_checkpoints/`.
  #
  # Nothing calls `restore/1` or `delete/1` — `Verification.Loop.init/1` always
  # builds a fresh struct at `iteration: 0` — so every loop that ever ran left a
  # JSON file behind and the directory grew for the life of the install. The
  # files are still written (they are the only forensic record of a loop's
  # iterations), but oldest-first pruning keeps the directory bounded.
  @max_checkpoints 200

  defp prune do
    dir = checkpoint_dir()

    files =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&Path.join(dir, &1))

    overflow = length(files) - @max_checkpoints

    if overflow > 0 do
      files
      |> Enum.map(fn path ->
        mtime =
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: m}} -> m
            _ -> 0
          end

        {mtime, path}
      end)
      |> Enum.sort()
      |> Enum.take(overflow)
      |> Enum.each(fn {_mtime, path} -> File.rm(path) end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v) when is_atom(v) and v not in [true, false, nil], do: to_string(v)
  defp stringify_value(v), do: v
end
