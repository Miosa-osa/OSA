defmodule OptimalSystemAgent.Agent.Loop.ToolResultStorage do
  @moduledoc """
  Tool result persistence — large tool results are written to disk and
  replaced with a reference. Prevents context window bloat from massive
  tool outputs (e.g., large file reads, verbose shell output).

  Results under the threshold are returned inline as usual.
  Results over the threshold are persisted to ~/.osa/tool-results/<id>.txt
  and the inline content is replaced with a head+tail preview plus a
  reference to the full file (steal-list #16 / reconciliation U-A4: opencode
  `tool/truncate.ts`).

  ## Thresholds (config-gated)

  A result is offloaded when it exceeds EITHER limit:
    * `:max_tool_output_bytes` (default 51_200 / 50KB) — byte-size cap.
    * `:max_tool_output_lines` (default 2_000) — line-count cap, so a huge
      number of short lines (e.g. `grep -r` across a big tree) triggers the
      same protection a single huge blob does, even under the byte cap.

  Preview shape (config-gated): `:tool_output_preview_head_lines` (default
  40) lines from the start, then an omitted-count marker, then
  `:tool_output_preview_tail_lines` (default 20) lines from the end — so the
  model sees both "what this command started doing" and "how it ended"
  without paying for the middle.
  """
  require Logger

  alias OptimalSystemAgent.ConfigFile

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  defp results_dir, do: Path.join(ConfigFile.config_dir(), "tool-results")
  # 50KB — mirrors opencode's MAX_BYTES.
  @default_byte_threshold 51_200
  # 2000 lines — mirrors opencode's MAX_LINES.
  @default_line_threshold 2_000
  @default_preview_head_lines 40
  @default_preview_tail_lines 20
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
      byte_threshold =
        Application.get_env(
          :optimal_system_agent,
          :max_tool_output_bytes,
          @default_byte_threshold
        )

      line_threshold =
        Application.get_env(
          :optimal_system_agent,
          :max_tool_output_lines,
          @default_line_threshold
        )

      line_count = count_lines(result_str)

      if byte_size(result_str) > byte_threshold or line_count > line_threshold do
        persist_and_reference(
          result_str,
          tool_name,
          tool_call_id,
          session_id,
          byte_threshold,
          line_count
        )
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
    pattern = Path.join(results_dir(), "#{sanitize_component(session_id)}_*")

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

    Path.join(results_dir(), "*.txt")
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

  # No `read/1` here on purpose: offloaded results are re-read by the model
  # itself through the `file_read` tool, using the path embedded in
  # `reference_note/3`. A module-local reader had zero callers.

  # ── Private ──────────────────────────────────────────────────────────

  defp persist_and_reference(
         result_str,
         tool_name,
         tool_call_id,
         session_id,
         threshold,
         line_count
       ) do
    File.mkdir_p!(results_dir())

    # Filename embeds the session so `cleanup/1`'s `<session>_*` glob matches and
    # per-session results are actually deleted on session end (previously named
    # `<callid>_<tool>.txt`, so the session glob never matched and offloaded
    # results leaked into ~/.osa/tool-results forever).
    safe_name = sanitize_component(tool_name)
    safe_id = sanitize_component(tool_call_id)
    safe_session = sanitize_component(session_id)
    filename = "#{safe_session}_#{safe_id}_#{safe_name}.txt"
    path = Path.join(results_dir(), filename)

    case File.write(path, result_str) do
      :ok ->
        size_kb = Float.round(byte_size(result_str) / 1024, 1)

        Logger.debug(
          "[tool_result_storage] Persisted #{tool_name} result (#{size_kb}KB, #{line_count} lines) to #{path}"
        )

        preview = head_tail_preview(result_str, line_count)

        "#{preview}\n\n#{reference_note(path, size_kb, line_count)}"

      {:error, reason} ->
        Logger.warning("[tool_result_storage] Failed to persist: #{reason}")
        # Fall back to inline truncation (no file to reference).
        String.slice(result_str, 0, threshold) <>
          "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first #{threshold} bytes]"
    end
  rescue
    _ ->
      String.slice(result_str, 0, threshold) <>
        "\n\n[Output truncated — #{byte_size(result_str)} bytes total]"
  end

  # Head+tail preview: first N lines, an omitted-count marker, last M lines.
  # Both bounds are config-gated so callers can tune preview size without a
  # code change. Falls back to a single head slice if the content has too
  # few lines for a meaningful head+tail split.
  defp head_tail_preview(result_str, line_count) do
    head_n =
      Application.get_env(
        :optimal_system_agent,
        :tool_output_preview_head_lines,
        @default_preview_head_lines
      )

    tail_n =
      Application.get_env(
        :optimal_system_agent,
        :tool_output_preview_tail_lines,
        @default_preview_tail_lines
      )

    if line_count > head_n + tail_n do
      lines = String.split(result_str, "\n")
      head = lines |> Enum.take(head_n) |> Enum.join("\n")
      tail = lines |> Enum.take(-tail_n) |> Enum.join("\n")
      omitted = line_count - head_n - tail_n

      "#{head}\n\n… #{omitted} lines omitted …\n\n#{tail}"
    else
      # Too few lines for a meaningful head+tail split by LINE (e.g. one
      # enormous single-line blob) — fall back to a byte-based head+tail
      # split so the preview still shrinks relative to the original.
      byte_head_tail_preview(result_str)
    end
  end

  # Byte-based head+tail fallback for content with too few newlines to slice
  # by line (a single giant line, minified JSON, etc). Each side is capped at
  # `head_n`/`tail_n` KILOBYTES reinterpreted as a byte budget — reuses the
  # same config knobs, just as a byte count instead of a line count, so a
  # single set of thresholds covers both shapes of "too big" output.
  defp byte_head_tail_preview(result_str) do
    head_n =
      Application.get_env(
        :optimal_system_agent,
        :tool_output_preview_head_lines,
        @default_preview_head_lines
      )

    tail_n =
      Application.get_env(
        :optimal_system_agent,
        :tool_output_preview_tail_lines,
        @default_preview_tail_lines
      )

    # ~80 bytes/"line" is a reasonable stand-in when there's no newline
    # structure to count lines against.
    head_bytes = head_n * 80
    tail_bytes = tail_n * 80
    total = byte_size(result_str)

    if total <= head_bytes + tail_bytes do
      result_str
    else
      head = binary_part(result_str, 0, head_bytes)
      tail = binary_part(result_str, total - tail_bytes, tail_bytes)
      omitted = total - head_bytes - tail_bytes

      "#{head}\n\n… #{omitted} bytes omitted …\n\n#{tail}"
    end
  end

  # Capability-aware reference note: mention the `delegate` sub-agent tool as
  # an option for processing the full output only when it's actually
  # registered in this build (opencode `truncate.ts` gates its hint the same
  # way on whether the Task tool is available to the current agent).
  defp reference_note(path, size_kb, line_count) do
    base =
      "[Full output written to #{path} (#{line_count} lines, #{size_kb}KB) — " <>
        "read it with file_read (with offset/limit) or grep_search it if needed."

    if delegate_available?() do
      base <>
        " For very large outputs, consider delegating to a sub-agent via delegate " <>
        "to process this file instead of reading it all into your own context.]"
    else
      base <> "]"
    end
  end

  defp delegate_available? do
    case OptimalSystemAgent.Tools.Registry.module_for("delegate") do
      nil -> false
      mod when is_atom(mod) -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp count_lines(str) do
    # String.split/2 always yields at least one element, so this counts
    # "line count" the way a human/model would (newline-separated segments),
    # matching how the head/tail preview slices the same split.
    str |> String.split("\n") |> length()
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
