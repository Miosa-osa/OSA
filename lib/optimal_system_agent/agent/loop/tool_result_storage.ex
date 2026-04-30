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

  @doc """
  Apply result budget to a tool result string.

  If the result exceeds the threshold, persist to disk and return a reference.
  Otherwise return the result unchanged.
  """
  def apply_budget(result_str, tool_name, tool_call_id) when is_binary(result_str) do
    threshold =
      Application.get_env(:optimal_system_agent, :max_tool_output_bytes, @default_threshold)

    if byte_size(result_str) > threshold do
      persist_and_reference(result_str, tool_name, tool_call_id, threshold)
    else
      result_str
    end
  end

  def apply_budget(result, _tool_name, _tool_call_id), do: result

  @doc """
  Clean up tool result files for a session (called on session end).
  """
  def cleanup(session_id) do
    pattern = Path.join(@results_dir, "#{session_id}_*")

    case Path.wildcard(pattern) do
      [] ->
        :ok

      files ->
        Enum.each(files, &File.rm/1)

        Logger.debug(
          "[tool_result_storage] Cleaned up #{length(files)} result files for #{session_id}"
        )
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

  defp persist_and_reference(result_str, tool_name, tool_call_id, threshold) do
    File.mkdir_p!(@results_dir)

    # Generate a unique filename
    safe_name = Regex.replace(~r/[^a-zA-Z0-9_\-]/, tool_name, "_")
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, to_string(tool_call_id), "_")
    filename = "#{safe_id}_#{safe_name}.txt"
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
end
