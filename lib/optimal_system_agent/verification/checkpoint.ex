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

  @doc "Full path to the checkpoint file for `loop_id`."
  @spec checkpoint_path(String.t()) :: String.t()
  def checkpoint_path(loop_id) do
    Path.join(checkpoint_dir(), "#{loop_id}.json")
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
            :ok

          {:error, reason} ->
            Logger.warning("[Verification.Checkpoint] Write failed for #{loop_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[Verification.Checkpoint] JSON encode failed for #{loop_id}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Verification.Checkpoint] Unexpected error saving #{loop_id}: #{Exception.message(e)}")
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
              Logger.warning("[Verification.Checkpoint] JSON decode failed for #{loop_id}: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.warning("[Verification.Checkpoint] Read failed for #{loop_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, nil}
    end
  rescue
    e ->
      Logger.warning("[Verification.Checkpoint] Unexpected error restoring #{loop_id}: #{Exception.message(e)}")
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
        Logger.warning("[Verification.Checkpoint] Delete failed for #{loop_id}: #{inspect(reason)}")
        :ok
    end
  end

  # --- Private ---

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
