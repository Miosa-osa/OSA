defmodule OptimalSystemAgent.Shell.TaskOutput do
  @moduledoc """
  Per-task on-disk output files for background shell commands (WS6).

  Every background task started with a session id mirrors its merged
  stdout/stderr stream to `<tmp>/osa/<session>/tasks/<task-id>.out` so:

    * the model can read the FULL output with the read tool (the in-memory
      buffer is head-truncated at 512 KiB);
    * the `<task-notification>` XML can point at a durable output-file;
    * a TUI detail view can tail it without holding it all in memory.

  Writes are plain appends; a per-file byte cap stops a runaway command from
  filling the disk — once the cap is reached a single truncation marker is
  written and further chunks are dropped (CC diskOutput parity, simplified).
  """
  require Logger

  # 5 GB per-file cap (CC diskOutput parity).
  @max_file_bytes 5 * 1024 * 1024 * 1024
  @truncation_marker "\n[... output truncated: file cap reached ...]\n"

  @doc "Absolute path of the output file for `{session_id, task_id}`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(session_id, task_id) when is_binary(session_id) and is_binary(task_id) do
    Path.join([base_dir(session_id), "tasks", sanitize(task_id) <> ".out"])
  end

  @doc """
  Append a chunk to the task's output file, creating parent dirs on first
  write. Always returns `:ok` — persistence is best-effort and must never
  crash the task worker.
  """
  @spec append(String.t() | nil, String.t(), binary()) :: :ok
  def append(nil, _task_id, _data), do: :ok
  def append(_sid, _task_id, data) when not is_binary(data), do: :ok

  def append(session_id, task_id, data) do
    file = path(session_id, task_id)
    File.mkdir_p!(Path.dirname(file))

    case File.stat(file) do
      {:ok, %{size: size}} when size >= @max_file_bytes ->
        :ok

      {:ok, %{size: size}} when size + byte_size(data) > @max_file_bytes ->
        _ = File.write(file, @truncation_marker, [:append])
        :ok

      _ ->
        _ = File.write(file, data, [:append])
        :ok
    end
  rescue
    e ->
      Logger.debug("[task-output] append failed for #{task_id}: #{Exception.message(e)}")
      :ok
  end

  defp base_dir(session_id),
    do: Path.join([System.tmp_dir!(), "osa", sanitize(session_id)])

  # Ids are internally generated, but never trust them as path segments —
  # strip separators, then collapse any remaining dot-dot traversal.
  defp sanitize(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.replace("..", "_")
  end
end
