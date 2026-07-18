defmodule OptimalSystemAgent.Agent.Loop.ToolResultStorage do
  @moduledoc """
  Tool result persistence — large tool results are written to disk and
  replaced with a reference. Prevents context window bloat from massive
  tool outputs (e.g., large file reads, verbose shell output).

  Results under the threshold are returned inline as usual.
  Results over the threshold are persisted to ~/.osa/tool-results/<id>.txt
  and the inline content is replaced with a reference.
  """
  require Logger

  @results_dir Path.expand("~/.osa/tool-results")
  # 10KB
  @default_threshold 10_240
  # Orphan sweep: delete result files older than this many days.
  @orphan_max_age_days 7

  @doc """
  Apply result budget to a tool result string.

  If the result exceeds the threshold, persist to disk and return a reference.
  Otherwise return the result unchanged.
  """
  def apply_budget(result_str, tool_name, tool_call_id, session_id \\ nil)

  def apply_budget(result_str, tool_name, tool_call_id, session_id) when is_binary(result_str) do
    # verbose (CC-parity): when set, show full tool output — bypass the byte
    # budget entirely so nothing is truncated or off-loaded to disk.
    if OptimalSystemAgent.Settings.get("verbose", false) == true do
      result_str
    else
      threshold =
        Application.get_env(:optimal_system_agent, :max_tool_output_bytes, @default_threshold)

      if byte_size(result_str) > threshold do
        persist_and_reference(result_str, tool_name, tool_call_id, session_id, threshold)
      else
        result_str
      end
    end
  end

  def apply_budget(result, _tool_name, _tool_call_id, _session_id), do: result

  @doc """
  Clean up tool result files for a session (called on session end).

  Files are named `<session>_<callid>_<tool>.txt` so the session-scoped glob
  matches. Also runs the age-based orphan sweep so files from crashed sessions
  (or written before a session_id was threaded through) can't accumulate forever.
  """
  def cleanup(session_id) do
    pattern = Path.join(@results_dir, "#{sanitize_component(session_id)}_*")

    case Path.wildcard(pattern) do
      [] ->
        :ok

      files ->
        Enum.each(files, &File.rm/1)

        Logger.debug(
          "[tool_result_storage] Cleaned up #{length(files)} result files for #{session_id}"
        )
    end

    sweep_orphans()
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Delete tool-result files older than `max_age_days` (default 7). Safety net for
  orphans whose per-session `cleanup/1` never ran (crash, or a nil session_id).
  Safe to call on startup and after each session.
  """
  @spec sweep_orphans(pos_integer()) :: :ok
  def sweep_orphans(max_age_days \\ @orphan_max_age_days) do
    cutoff = System.system_time(:second) - max_age_days * 86_400

    Path.join(@results_dir, "*.txt")
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, acc ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) and mtime < cutoff ->
          case File.rm(path) do
            :ok -> acc + 1
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> case do
      0 ->
        :ok

      removed ->
        Logger.debug(
          "[tool_result_storage] Swept #{removed} orphaned result file(s) older than #{max_age_days}d"
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Read a persisted tool result by its file path.
  """
  def read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read stored result: #{reason}"}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp persist_and_reference(result_str, tool_name, tool_call_id, session_id, threshold) do
    File.mkdir_p!(@results_dir)

    # Filename embeds the session so `cleanup/1`'s `<session>_*` glob matches and
    # per-session results are actually deleted on session end (previously named
    # `<callid>_<tool>.txt`, so the session glob never matched and offloaded
    # results leaked into ~/.osa/tool-results forever).
    safe_name = sanitize_component(tool_name)
    safe_id = sanitize_component(tool_call_id)
    safe_session = sanitize_component(session_id)
    filename = "#{safe_session}_#{safe_id}_#{safe_name}.txt"
    path = Path.join(@results_dir, filename)

    case File.write(path, result_str) do
      :ok ->
        size_kb = Float.round(byte_size(result_str) / 1024, 1)
        preview = String.slice(result_str, 0, min(threshold, 2000))

        Logger.debug(
          "[tool_result_storage] Persisted #{tool_name} result (#{size_kb}KB) to #{path}"
        )

        "#{preview}\n\n[Full output persisted: #{path} (#{size_kb}KB) — use file_read to access if needed]"

      {:error, reason} ->
        Logger.warning("[tool_result_storage] Failed to persist: #{reason}")
        # Fall back to truncation
        String.slice(result_str, 0, threshold) <>
          "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first #{threshold} bytes]"
    end
  rescue
    _ ->
      String.slice(result_str, 0, threshold) <>
        "\n\n[Output truncated — #{byte_size(result_str)} bytes total]"
  end

  # Sanitize a filename component: keep [A-Za-z0-9_-], collapse everything else
  # to `_`; nil/empty → "nosession" so nil session_ids get a stable prefix.
  defp sanitize_component(nil), do: "nosession"

  defp sanitize_component(value) do
    case Regex.replace(~r/[^a-zA-Z0-9_\-]/, to_string(value), "_") do
      "" -> "nosession"
      s -> s
    end
  end
end
