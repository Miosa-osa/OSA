defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_edit`.

  Three-stage pipeline:
    * `validate/2`            — type checks input shape (cheap)
    * `check_permissions/2`   — path allowlist + blocked write-path deny
    * `execute/2`             — actual file edit

  Logic was moved verbatim from the original `file_edit.ex`. No semantic changes —
  just relocation + validation/permission split.

  ## Return shapes
  On success, `execute/2` returns:
    * `{:ok, result, %{diff: diff_text, stats: diff_stats, path: resolved}}` when a
      non-empty unified diff is available — the SSE consumer and Rust TUI depend on
      these fields being present.
    * `{:ok, result}` (2-tuple) when the diff is empty (replace_all with 1 occurrence).

  The 3-tuple shape is preserved exactly from the original.
  """

  alias OptimalSystemAgent.Agent.Safety.PathCanon
  alias OptimalSystemAgent.Tools.Ablation
  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path, "old_string" => old, "new_string" => new} = input, _ctx)
      when is_binary(path) and is_binary(old) and is_binary(new),
      do: {:ok, input}

  def validate(%{"path" => _, "old_string" => _, "new_string" => _}, _ctx),
    do: {:error, "path, old_string, and new_string must all be strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: path, old_string, new_string", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    # One shared decision (`PathPolicy.check_write/2`) for all four write
    # tools. It canonicalises first, so an intermediate directory symlink
    # cannot smuggle the target out of the allowed roots, and it applies the
    # dotfile and blocked-location rules that used to differ per tool.
    with :ok <- PathPolicy.check_read(path, path),
         :ok <- PathPolicy.check_write(path, path) do
      {:allow, input}
    else
      {:deny, _} = denial -> denial
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()}
          | {:ok, String.t(), map()}
          | {:error, String.t()}
  def execute(%{"path" => path, "old_string" => old, "new_string" => new} = params, ctx) do
    expanded = Path.expand(path)
    replace_all = params["replace_all"] == true
    resolved = resolve_real_path(expanded)

    cond do
      old == new ->
        {:error, "old_string and new_string are identical"}

      old == "" ->
        {:error, "old_string cannot be empty"}

      true ->
        # Defense-in-depth: re-run the write guard here so the sandbox holds
        # even when `execute/2` is invoked directly, bypassing the
        # validate → check_permissions → execute pipeline. `file_write` already
        # did this; `file_edit`, which is equally write-capable, did not.
        case PathPolicy.check_write(path, path) do
          :ok -> do_edit(resolved, path, old, new, replace_all, session_id(ctx))
          {:deny, msg} -> {:error, msg}
        end
    end
  end

  def execute(_, _ctx),
    do: {:error, "Missing required parameters: path, old_string, new_string"}

  # ── Private ───────────────────────────────────────────────────────────

  defp do_edit(expanded, display_path, old, new, replace_all, session) do
    case File.read(expanded) do
      {:ok, content} ->
        # Read-before-edit / stale-write guard (P0-1). The file exists and is
        # readable here; reject if the model never read it this session or if it
        # changed on disk since that read (linter/user/sub-agent touched it).
        {mtime, size} = stat_or_zero(expanded)

        with :ok <- FileState.check_read(session, expanded),
             # Hashline-style content-drift guard (P1 #6 / U-A2) — independent,
             # second layer on top of FileState's mtime/size check. Only fires
             # inside the exact-{mtime,size}-collision window FileState's own
             # check can't see; see DriftGuard moduledoc.
             :ok <- DriftGuard.verify(session, expanded, content, mtime, size) do
          do_edit_apply(expanded, display_path, old, new, replace_all, content, session)
        else
          {:error, msg} -> {:error, msg}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{display_path}"}

      {:error, reason} ->
        {:error, "Cannot read #{display_path}: #{reason}"}
    end
  end

  defp do_edit_apply(expanded, display_path, old, new, replace_all, content, session) do
    # Codex V4A-style 3-stage cascade (exact → line-endings → whitespace) so
    # trivial whitespace / line-ending drift doesn't fail an otherwise-valid
    # edit. Matcher.replace preserves the exact-match fast path verbatim.
    case Matcher.replace(content, old, new, replace_all) do
      {:error, :not_found} ->
        already_applied_or_not_found(content, display_path, new)

      {:error, :ambiguous, count} ->
        {:error,
         "old_string found #{count} times in #{display_path} — must be unique. " <>
           ambiguous_locations_note(content, old) <>
           "Next step: extend old_string with surrounding context from one of those " <>
           "locations so it matches exactly once, or set replace_all: true to change all #{count}."}

      {:error, :disproportionate} ->
        {:error,
         "Refusing edit in #{display_path}: the fuzzy-matched region is much larger than old_string. " <>
           "Re-read the file and provide the exact text to replace."}

      {:error, {:replace_all_approximate, strategy}} ->
        {:error,
         "Refusing replace_all in #{display_path}: old_string does not appear in the file " <>
           "verbatim — it only matched approximately (fuzzy #{strategy} match). " <>
           "An approximate match identifies ONE candidate region; it is not evidence about " <>
           "every region that resembles it, so replacing globally would rewrite regions that " <>
           "never contained old_string. " <>
           "Next step: re-read #{display_path}, then either (a) supply a longer old_string that " <>
           "matches the file exactly and retry with replace_all, or (b) drop replace_all and " <>
           "edit each site individually with its own exact old_string."}

      {:ok, new_content, occurrences, stage} ->
        # Non-bang write with clean error reporting (mirrors file_write). A
        # read-only file / read-only mount / ENOSPC otherwise raises File.Error
        # and surfaces as the opaque blanket registry rescue message.
        case File.write(expanded, new_content) do
          {:error, reason} ->
            {:error, "Cannot write #{display_path}: #{:file.format_error(reason)}"}

          :ok ->
            # Refresh read-state to the just-written file so a follow-up edit in
            # the same turn is not falsely flagged stale (P0-1).
            FileState.record_write(session, expanded)

            # Refresh the drift-guard baseline to the just-written content
            # (and its fresh mtime/size) so a follow-up edit in the same
            # session compares against what THIS edit produced (P1 #6 / U-A2).
            {new_mtime, new_size} = stat_or_zero(expanded)
            DriftGuard.record(session, expanded, new_content, new_mtime, new_size)

            # Post-edit validation hook (P1-4). Run SYNCHRONOUSLY (was
            # fire-and-forget with errors swallowed) so a compile/lint failure on
            # the edited file is surfaced to the model in the SAME observation
            # instead of being discovered 20 tool-calls later. Non-fatal: the
            # edit already landed; we only append the diagnostic.
            hook_note =
              file_changed_note(%{
                path: expanded,
                tool: "file_edit",
                operation: :edit
              })

            # The :file_changed hook may be a formatter/linter that REWRITES the
            # file. If so, the baseline recorded above (from OUR bytes) is now
            # stale versus disk, and the NEXT edit would trip the read-before-
            # edit / drift guard with a spurious "re-read the file first" — the
            # rapid-edit churn users hit when a format-on-save hook is active.
            # Re-capture from the final on-disk bytes so the guards reflect what
            # is actually there.
            refresh_write_baseline(session, expanded)

            # Generate unified diff (delegates to Utils.Diff for proper unified format)
            {diff_text, diff_stats} =
              OptimalSystemAgent.Utils.Diff.unified(content, new_content, display_path)

            fuzzy_note = if stage == :exact, do: "", else: " (fuzzy #{stage} match)"

            base_result =
              edit_report(%{
                display_path: display_path,
                stage: stage,
                fuzzy_note: fuzzy_note,
                replace_all: replace_all,
                occurrences: occurrences,
                old: old,
                new: new,
                content: content,
                diff: diff_text
              })

            result = base_result <> hook_note

            # Attach diff metadata for SSE consumers (3-tuple) when diff is non-empty
            if diff_text != "" do
              {:ok, result, %{diff: diff_text, stats: diff_stats, path: expanded}}
            else
              {:ok, result}
            end
        end
    end
  end

  # ── What a successful edit reports back to the model ──────────────────
  #
  # An **exact** match gets a one-line confirmation and no diff.
  #
  # The model supplied `old_string` and `new_string` in the request. On an exact
  # match, "it matched verbatim and was replaced" adds nothing the model does not
  # already hold — so echoing a synthetic diff of those same two strings pays for
  # the edit twice: once outbound in the arguments, once inbound in the result,
  # and then permanently, because the result stays in the transcript for the rest
  # of the session. Measured on `schemelike-metacircular-eval`: 58 edits at a
  # median argument of 506 bytes. Measured here on a 76-byte `old_string`: the
  # result was 374 bytes, of which 335 was the echo.
  #
  # A **fuzzy** match keeps the diff, and this is the whole reason the split
  # exists rather than a blanket removal. Under the line-endings/whitespace
  # cascade (`Matcher`), `old_string` did NOT appear in the file verbatim — the
  # matcher chose a region that merely resembles it. What actually changed is
  # therefore genuinely new information, and it is the model's only chance to
  # notice that the edit landed somewhere it did not intend. That is a
  # correctness signal, not an echo, so it is not something to economise on.
  #
  # `replace_all` with multiple occurrences already returned no diff (a single
  # hunk cannot describe N sites), which is unchanged.
  #
  # The unified diff for the TUI is untouched: it travels in the 3-tuple's
  # `:diff` metadata field, which SSE consumers and the Rust TUI read, and which
  # was never part of the model-facing string.
  defp edit_report(%{replace_all: true, occurrences: n} = r) when n > 1,
    do: "Replaced #{n} occurrences in #{r.display_path}#{r.fuzzy_note}"

  # Behind `:edit_diff_echo`, which is the one ablation flag whose ON state is
  # NOT production — the echo was already removed. Enabling it restores the old
  # behaviour so the harness can price a decision already taken, rather than
  # taking the commit message's word for it.
  defp edit_report(%{stage: :exact} = r) do
    if Ablation.on?(:edit_diff_echo) do
      "Replaced in #{r.display_path}" <> diff_body(r)
    else
      "Replaced in #{r.display_path}"
    end
  end

  defp edit_report(r) do
    "Replaced in #{r.display_path}#{r.fuzzy_note}" <> diff_body(r)
  end

  # The diff the model is shown is the SAME diff the TUI is shown — the real
  # one, computed by `Utils.Diff.unified/3` from the before and after content.
  #
  # It used to be a separate, hand-rolled rendering that located its hunk by
  # scanning for the first line in the file *containing* the first line of
  # `old_string`:
  #
  #     start_idx = Enum.find_index(lines, &String.contains?(&1, first_old_line)) || 0
  #
  # Three ways that is wrong, and all three were observable in the benchmark
  # transcripts. A common first line (`    return`, `def __init__(self):`, or
  # `""` when `old_string` began with a newline) anchors the hunk at the FIRST
  # such line anywhere in the file; the `|| 0` anchors it at line 1 when nothing
  # matches at all; and the context lines are then sliced from that wrong index,
  # so the model is shown real code from a region the edit never touched. The
  # hunk header `@@ -N,M @@` compounded it — no `+` side, and `M` a fiction
  # (`length(old_lines) + 4`).
  #
  # This is worst on exactly the path that still renders a diff. A fuzzy match
  # means `old_string` does NOT appear verbatim, so `String.contains?/2` on its
  # first line is least likely to find the real site and most likely to land on
  # `|| 0`. The one case where the diff is a correctness signal is the case
  # where it was most reliably misleading.
  #
  # Measured in the corpus (118 SWE-bench/-Pro transcripts): 50 assistant
  # statements calling the returned diff "misleading", "garbled", "confusing",
  # or "landed in the wrong place", across 21 sessions — several followed by a
  # full re-read of the file to find out what actually happened. The exact/fuzzy
  # split shipped earlier does not touch this: it removes the diff on exact
  # matches and keeps this renderer on fuzzy ones.
  #
  # The file header (`--- a/path` / `+++ b/path`) is dropped because the line
  # above it already names the path; the hunks are what carry information.
  defp diff_body(r) do
    if Ablation.on?(:edit_diff_anchor) do
      real_diff_body(r)
    else
      "\n" <> legacy_format_diff(r.old, r.new, r.content, r.display_path)
    end
  end

  defp real_diff_body(%{diff: diff}) when is_binary(diff) and diff != "" do
    "\n" <>
      (diff
       |> String.split("\n")
       |> Enum.drop_while(&(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))
       |> Enum.join("\n"))
  end

  defp real_diff_body(_), do: ""

  # The renderer described above, kept ONLY so `:edit_diff_anchor` can price the
  # fix by restoring it. Nothing in production reaches this.
  defp legacy_format_diff(old, new, content, path) do
    lines = String.split(content, "\n")
    old_lines = String.split(old, "\n")
    first_old_line = List.first(old_lines) || ""

    start_idx = Enum.find_index(lines, fn l -> String.contains?(l, first_old_line) end) || 0

    ctx_before = Enum.slice(lines, max(start_idx - 2, 0), min(2, start_idx))
    ctx_after = Enum.slice(lines, start_idx + length(old_lines), 2)

    removed = Enum.map(old_lines, fn l -> "- #{l}" end)
    added = new |> String.split("\n") |> Enum.map(fn l -> "+ #{l}" end)
    context_b = Enum.map(ctx_before, fn l -> "  #{l}" end)
    context_a = Enum.map(ctx_after, fn l -> "  #{l}" end)

    header = "--- #{path}\n+++ #{path}"
    hunk = "@@ -#{max(start_idx - 1, 1)},#{length(old_lines) + 4} @@"

    Enum.join([header, hunk] ++ context_b ++ removed ++ added ++ context_a, "\n")
  end

  # ── Idempotent re-application ─────────────────────────────────────────
  #
  # A retry after a partial success used to be unrecoverable: the first attempt
  # applied the edit, so `old_string` is gone, so the retry hard-errors
  # "old_string not found" — forever, no matter how many times it is retried.
  # The agent dead-ends on a file that is ALREADY in the state it asked for.
  #
  # An edit is a request for a target state, and that state holds. So when
  # old_string is absent but new_string is present, report success as a NO-OP.
  # This is strictly narrower than "ignore missing matches":
  #
  #   * `new` must be non-empty — a deletion (`new == ""`) is vacuously
  #     "present" in every file, so treating it as applied would swallow every
  #     genuinely failed deletion. Deletions keep the hard error.
  #   * `new` must actually occur in the current content.
  #
  # No file is written and no drift-guard/read-state baseline moves, so this
  # cannot mask a stale-write: it is a pure read-and-report path.
  defp already_applied_or_not_found(content, display_path, new) do
    if new != "" and String.contains?(content, new) do
      {:ok,
       "No change needed in #{display_path}: old_string is absent and new_string is already " <>
         "present, so this edit was already applied. The file is in the requested state — " <>
         "continue with the next step rather than retrying."}
    else
      {:error,
       "old_string not found in #{display_path}. " <>
         "Next step: re-read #{display_path} with file_read and copy old_string verbatim " <>
         "from the output (including indentation), then retry."}
    end
  end

  # Ambiguity is reported with a count but not with WHERE, so the model has to
  # re-read the file and hunt for the duplicates itself. The line numbers are a
  # cheap scan of content we have already loaded — hand them over.
  defp ambiguous_locations_note(content, old) do
    first_old_line = old |> String.split("\n") |> List.first() |> to_string()

    lines =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} ->
        first_old_line != "" and String.contains?(line, first_old_line)
      end)
      |> Enum.map(fn {_line, n} -> n end)
      |> Enum.take(20)

    case lines do
      [] -> ""
      nums -> "Candidate locations (line numbers): #{Enum.join(nums, ", ")}. "
    end
  end

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  # POSIX {mtime, size} for DriftGuard (P1 #6 / U-A2). A stat failure between
  # our own successful File.read/File.write and this call (file vanished, odd
  # filesystem race) degrades to `{0, 0}` — DriftGuard treats that like any
  # other non-matching identity and simply defers (see moduledoc), never a
  # false rejection.
  defp stat_or_zero(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      _ -> {0, 0}
    end
  end

  # Run the :file_changed validation hook SYNCHRONOUSLY and turn any reported
  # failure (a compile/lint diagnostic on the edited file) into a note appended
  # to the tool observation, so the model self-corrects in the same turn (P1-4).
  #
  # Returns "" when the hook reports nothing (the common case: no post-edit
  # validation hook registered). Always non-fatal — never raises into the caller.
  @spec file_changed_note(map()) :: String.t()
  @doc false
  # Re-capture the read-before-edit and drift baselines from a file's CURRENT
  # on-disk bytes, after a `:file_changed` hook (e.g. a formatter) may have
  # rewritten it. Without this, a format-on-save hook leaves every write's
  # baseline stale and the next edit is falsely rejected as "re-read first".
  # Best-effort: a vanished/unreadable file just leaves the prior baseline.
  @spec refresh_write_baseline(term(), String.t()) :: :ok
  def refresh_write_baseline(session, path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{mtime: mtime, size: size}} <- File.stat(path, time: :posix) do
      # record_write re-stats + re-hashes internally; pass the fresh content to
      # DriftGuard so both guards agree with disk.
      FileState.record_write(session, path)
      DriftGuard.record(session, path, content, mtime, size)
    end

    :ok
  rescue
    _ -> :ok
  end

  def file_changed_note(payload) do
    diagnostic =
      try do
        case OptimalSystemAgent.Agent.Hooks.run(:file_changed, payload) do
          {:ok, result} when is_map(result) -> extract_diagnostic(result)
          {:blocked, reason} when is_binary(reason) -> reason
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    case diagnostic do
      nil -> ""
      "" -> ""
      text -> "\n\n⚠ Post-edit validation reported a problem — fix before continuing:\n" <> text
    end
  end

  # Pull human-readable diagnostics out of the hook's final payload. A hook can
  # report a problem via the standard {:inject_context, text} channel (lands in
  # :injected_context) or by setting a :diagnostics / :validation_error field.
  defp extract_diagnostic(result) do
    [
      Map.get(result, :injected_context, []),
      Map.get(result, :diagnostics),
      Map.get(result, :validation_error)
    ]
    |> Enum.flat_map(fn
      nil -> []
      list when is_list(list) -> list
      other -> [other]
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  # Resolve symlinks BEFORE security checks to prevent symlink traversal attacks.
  # Resolves EVERY component, not just the last — `:file.read_link_all/1` alone
  # is not realpath (it reads one link's contents, and only when the leaf is
  # itself a link), which is what let a symlinked intermediate directory walk
  # straight past this guard. See `PathCanon`.
  defp resolve_real_path(path), do: PathCanon.canonicalize(path)
end
