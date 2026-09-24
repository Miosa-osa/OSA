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
  alias OptimalSystemAgent.Utils.Text

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
  # `expand/2` range-mode default line cap, so a handle expanded with no
  # explicit `:limit` still returns a bounded slice rather than the whole file.
  @default_expand_limit 200
  # `expand/2` grep-mode: matching lines returned, capped so a pattern that
  # matches almost everything cannot re-create the original context bloat.
  @max_grep_matches 200
  # Head/tail-adjacent lines that look like an error or a match, surfaced
  # alongside the head+tail preview so the model does not have to guess an
  # offset to see WHY a command failed. Deliberately small — this augments the
  # preview, it does not replace `expand/2` for genuine investigation.
  @max_key_lines 20
  @key_line_patterns [
    ~r/\berror\b/i,
    ~r/\bexception\b/i,
    ~r/\bfail(ed|ure)?\b/i,
    ~r/\btraceback\b/i,
    ~r/panic:/i,
    # Compiler/linter-style `path:line:col` locations.
    ~r/^\s*\S+:\d+:\d+/,
    ~r/✗|✘/
  ]

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

  @doc """
  Write `content` to the shared tool-results store and return `{:ok, path}`.

  This is the ONE place that decides the filename scheme
  (`<session>_<call_id>_<tool_name>.txt`, so `cleanup/1`'s session-scoped glob
  and `sweep_orphans/1`'s age sweep both cover it). `apply_budget/4`'s own
  offload goes through this too — added so `Agent.Loop.ContextReduce`'s
  cheaper stale-tool-result clearing tier, and anything else that needs to
  spill a result to disk, share the exact same store and naming instead of
  inventing a second one.
  """
  @spec persist(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def persist(content, tool_name, tool_call_id, session_id \\ nil) when is_binary(content) do
    File.mkdir_p!(results_dir())
    path = Path.join(results_dir(), filename(tool_name, tool_call_id, session_id))

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Read back a previously stored tool result, by handle or by its full path.

  `handle_or_path` is either the bare filename `persist/4`/`apply_budget/4`
  wrote (e.g. `sess123_call45_shell_execute.txt`) or the full path embedded in
  their reference notes — both resolve to the same file. Any other path,
  including one that tries to `..` its way out of the tool-results
  directory, is refused: this is a retrieval tool the model calls with
  untrusted-ish input, not a general file-read primitive.

  ## Options

    * `:grep` — a pattern (regex or literal substring); returns only matching
      lines, each prefixed with its 1-based line number.
    * `:offset` / `:limit` — 1-based starting line and max lines to return.
      Ignored when `:grep` is given. Defaults to the whole file capped at
      #{@default_expand_limit} lines.
  """
  @spec expand(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def expand(handle_or_path, opts \\ [])

  def expand(handle_or_path, opts) when is_binary(handle_or_path) do
    with {:ok, path} <- resolve_handle(handle_or_path),
         {:ok, content} <- read_stored(path) do
      case Keyword.get(opts, :grep) do
        nil -> {:ok, range_slice(content, opts)}
        pattern -> grep_slice(content, pattern, opts)
      end
    end
  end

  def expand(_handle_or_path, _opts), do: {:error, "handle must be a string"}

  # No `read/1` here on purpose beyond `expand/2` above: offloaded results are
  # re-read by the model itself through `file_read`/`expand_output`, using the
  # path or handle embedded in `reference_note/3`.

  # ── Private ──────────────────────────────────────────────────────────

  defp persist_and_reference(
         result_str,
         tool_name,
         tool_call_id,
         session_id,
         threshold,
         line_count
       ) do
    case persist(result_str, tool_name, tool_call_id, session_id) do
      {:ok, path} ->
        size_kb = Float.round(byte_size(result_str) / 1024, 1)

        Logger.debug(
          "[tool_result_storage] Persisted #{tool_name} result (#{size_kb}KB, #{line_count} lines) to #{path}"
        )

        preview = head_tail_preview(result_str, line_count)

        "#{preview}\n\n#{reference_note(path, size_kb, line_count)}"

      {:error, reason} ->
        Logger.warning("[tool_result_storage] Failed to persist: #{inspect(reason)}")
        # Fall back to inline truncation (no file to reference). `threshold` is
        # a BYTE cap, so this must be a byte-bounded cut — String.slice/3
        # counts graphemes and would emit ~3x the advertised size on CJK and
        # ~4x on emoji while claiming "showing first #{threshold} bytes".
        # Head AND tail, matching the on-disk preview above. A head-only cut
        # drops the end of the output, which for a build or a test run is the
        # part that says whether it passed — the single most likely reason the
        # tool was called at all.
        half = div(threshold, 2)

        Text.utf8_head(result_str, half) <>
          "\n\n[Output truncated — #{byte_size(result_str)} bytes total, " <>
          "showing first and last #{half} bytes; persisting the full result failed]\n\n" <>
          Text.utf8_tail(result_str, half)
    end
  rescue
    _ ->
      Text.utf8_head(result_str, threshold) <>
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
      key_section = key_lines_section(lines, line_count, head_n, tail_n)

      "#{head}\n\n… #{omitted} lines omitted …#{key_section}\n\n#{tail}"
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
      # Both cuts MUST be UTF-8 boundary-safe. This preview is handed straight
      # to the provider, whose request body goes through
      # `Jason.encode_to_iodata!/1` — that RAISES on invalid UTF-8, so an
      # unguarded `binary_part/3` here kills the turn rather than degrading it.
      # The tail is the dangerous one: a cut at `total - tail_bytes` starts
      # mid-sequence on almost any multibyte content (minified JSON with
      # escaped text, a base64 blob, a CJK or emoji log), while the head only
      # misbehaves when the boundary lands inside the final character.
      head = Text.utf8_head(result_str, head_bytes)
      tail = Text.utf8_tail(result_str, tail_bytes)
      omitted = total - byte_size(head) - byte_size(tail)

      "#{head}\n\n… #{omitted} bytes omitted …\n\n#{tail}"
    end
  end

  # Lines around (but outside) the visible head+tail window that look like an
  # error or a match. `lines` is the SAME split `head_tail_preview/2` already
  # computed — passed in rather than re-split so a multi-MB result is not
  # split twice per call.
  defp key_lines_section(lines, line_count, head_n, tail_n) do
    tail_start = max(line_count - tail_n + 1, head_n + 1)

    matches =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {_line, n} -> n > head_n and n < tail_start end)
      |> Enum.filter(fn {line, _n} -> matches_key_pattern?(line) end)
      |> Enum.take(@max_key_lines)

    case matches do
      [] ->
        ""

      _ ->
        body =
          Enum.map_join(matches, "\n", fn {line, n} ->
            "  L#{n}: #{String.slice(line, 0, 300)}"
          end)

        "\n\nKey lines (errors/matches):\n#{body}"
    end
  end

  defp matches_key_pattern?(line), do: Enum.any?(@key_line_patterns, &Regex.match?(&1, line))

  # Capability-aware reference note: mention the `delegate` sub-agent tool as
  # an option for processing the full output only when it's actually
  # registered in this build (opencode `truncate.ts` gates its hint the same
  # way on whether the Task tool is available to the current agent).
  #
  # Leads with a short `Handle:` line — the bare filename `expand/2` and the
  # `expand_output` tool resolve directly, without the model needing to
  # extract (or worse, retype) the full absolute path.
  defp reference_note(path, size_kb, line_count) do
    handle = Path.basename(path)

    base =
      "Handle: #{handle}\n" <>
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

  # Filename embeds the session so `cleanup/1`'s `<session>_*` glob matches and
  # per-session results are actually deleted on session end (previously named
  # `<callid>_<tool>.txt`, so the session glob never matched and offloaded
  # results leaked into ~/.osa/tool-results forever).
  defp filename(tool_name, tool_call_id, session_id) do
    safe_name = sanitize_component(tool_name)
    safe_id = sanitize_component(tool_call_id)
    safe_session = sanitize_component(session_id)
    "#{safe_session}_#{safe_id}_#{safe_name}.txt"
  end

  # ── expand/2 helpers ─────────────────────────────────────────────────

  # Resolves EITHER a bare handle (a filename `persist/4` produced) OR a full
  # path, always against the shared results directory, and refuses anything
  # that would land outside it (a `..`-laden handle, an absolute path
  # elsewhere on disk). `expand/2` is a retrieval tool a model calls with
  # input it read out of its own context — never a general file-read
  # primitive in disguise.
  defp resolve_handle(handle_or_path) do
    dir = results_dir()

    candidate =
      if Path.type(handle_or_path) == :absolute do
        Path.expand(handle_or_path)
      else
        Path.expand(Path.join(dir, handle_or_path))
      end

    if String.starts_with?(candidate, dir <> "/") do
      {:ok, candidate}
    else
      {:error,
       "Refusing to expand #{inspect(handle_or_path)} — it resolves outside the tool-results store."}
    end
  end

  defp read_stored(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "No stored output found for #{Path.basename(path)}."}
      {:error, reason} -> {:error, "Could not read #{Path.basename(path)}: #{inspect(reason)}"}
    end
  end

  defp range_slice(content, opts) do
    offset = max(Keyword.get(opts, :offset, 1), 1)
    limit = Keyword.get(opts, :limit, @default_expand_limit)

    lines = String.split(content, "\n")
    total = length(lines)
    slice = lines |> Enum.drop(offset - 1) |> Enum.take(limit)

    case slice do
      [] ->
        "Offset #{offset} is past the end of the stored output (#{total} lines total)."

      _ ->
        last = offset + length(slice) - 1
        "Lines #{offset}-#{last} of #{total}:\n#{Enum.join(slice, "\n")}"
    end
  end

  defp grep_slice(content, pattern, opts) when is_binary(pattern) do
    limit = Keyword.get(opts, :limit, @max_grep_matches)
    regex = compile_pattern(pattern)

    matches =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
      |> Enum.take(limit)

    case matches do
      [] ->
        {:ok, "No lines matched #{inspect(pattern)}."}

      _ ->
        body = Enum.map_join(matches, "\n", fn {line, n} -> "#{n}: #{line}" end)
        {:ok, "#{length(matches)} matching line(s):\n#{body}"}
    end
  end

  defp grep_slice(_content, _pattern, _opts), do: {:error, "grep pattern must be a string"}

  # A pattern the caller wrote as a regex (e.g. "line 42$") is honoured as
  # one; anything that fails to compile as a regex is treated as a literal
  # substring instead — so an unescaped user string like "foo(bar)" still
  # matches literally rather than erroring.
  defp compile_pattern(pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> regex
      {:error, _} -> Regex.compile!(Regex.escape(pattern), "i")
    end
  end
end
