defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `multi_file_edit`.

    * `validate/2`          — type checks input shape; verifies edits list is non-empty
    * `check_permissions/2` — path allowlist check on all edit targets
    * `execute/2`           — validate-then-apply edit sequence

  ## Return shapes

  On success, `execute/2` returns the rich 3-tuple:

      {:ok, summary_string, %{results: per_file_results, count: integer()}}

  where each element of `results` is:

      %{path: display_path, lines_changed: integer()}

  On validation failure (before any file is touched):

      {:error, reason_string}

  On partial apply failure (some files may have been modified):

      {:error, reason_string}

  The 3-tuple is preserved for SSE consumers and the Rust TUI — mirrors the
  pattern established by `FileEdit.Handler`.
  """

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEditHandler
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"edits" => edits} = input, _ctx) when is_list(edits) and length(edits) > 0,
    do: {:ok, input}

  def validate(%{"edits" => []}, _ctx),
    do: {:error, "edits list is empty", -32_602}

  def validate(%{"edits" => _}, _ctx),
    do: {:error, "edits must be a list of edit objects", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: edits", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"edits" => edits} = input, _ctx) when is_list(edits) do
    # The SAME write decision the other three write tools use
    # (`PathPolicy.check_write/2`). This call site used to have a private
    # `write_allowed?/1` that resolved no symlinks and had no dotfile clause at
    # all, so `multi_file_edit` could write where `file_edit` and `file_write`
    # both refused — the weakest of three copies decided the sandbox.
    denied =
      Enum.find_value(edits, fn
        %{"path" => path} when is_binary(path) ->
          case PathPolicy.check_write(normalize_path(path), path) do
            :ok -> nil
            {:deny, reason} -> reason
          end

        _ ->
          nil
      end)

    if denied do
      {:deny, denied}
    else
      {:allow, input}
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t(), map()} | {:error, String.t()}
  def execute(%{"edits" => edits}, ctx) when is_list(edits) do
    session = session_id(ctx)
    resolved = Enum.map(edits, &resolve_edit/1)
    validation_results = Enum.map(resolved, &validate_edit(&1, session))

    errors =
      Enum.filter(validation_results, fn
        {:error, _, _} -> true
        _ -> false
      end)

    # Hunks that are already in the requested state. Not errors and not work:
    # they are reported per-hunk in the observation and excluded from the
    # atomic apply set (there is nothing to write).
    already_applied =
      for {:already_applied, dp} <- validation_results, do: dp

    to_apply =
      Enum.filter(validation_results, fn
        {:valid, _, _, _, _, _, _} -> true
        _ -> false
      end)

    cond do
      errors != [] ->
        # A genuine failure still fails the whole batch — the atomicity and
        # read-before-edit guarantees are the point of this tool. But the
        # message now carries EVERY hunk's outcome, so the model can see which
        # ones were fine and reissue only what actually needs doing.
        {:error,
         "Validation failed — no files were modified:\n" <>
           per_hunk_report(errors, already_applied, to_apply)}

      to_apply == [] ->
        # Every hunk was already applied. This is the retry-after-partial-
        # success case: it is a success, not a failure.
        count = length(already_applied)

        {:ok,
         "No changes needed — all #{count} #{if count == 1, do: "edit", else: "edits"} " <>
           "were already applied:\n" <>
           Enum.map_join(already_applied, "\n", &"  #{&1} (already applied)") <>
           "\nThe files are in the requested state — continue with the next step " <>
           "rather than retrying.", %{results: [], count: 0, already_applied: already_applied}}

      true ->
        apply_validated(to_apply, already_applied, session)
    end
  end

  def execute(_, _ctx), do: {:error, "Missing required parameter: edits"}

  defp per_hunk_report(errors, already_applied, to_apply) do
    error_lines =
      Enum.map_join(errors, "\n", fn {:error, display_path, reason} ->
        "  - #{display_path}: #{reason}"
      end)

    applied_lines =
      Enum.map_join(already_applied, "\n", &"  - #{&1}: already applied (no change needed)")

    ok_lines =
      Enum.map_join(to_apply, "\n", fn {:valid, dp, _ep, _o, _n, _c, _nc} ->
        "  - #{dp}: would apply cleanly"
      end)

    [error_lines, applied_lines, ok_lines]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp apply_validated(validation_results, already_applied, session) do
    # Every remaining edit validated. Apply them ATOMICALLY (all-or-nothing) so
    # a write that fails partway can never leave the repo half-edited (BUG B).
    case apply_atomic(validation_results) do
      {:ok, per_file, applied} ->
        # Refresh read-state for every edited file (P0-1) and run the
        # post-edit validation hook synchronously per file, aggregating any
        # diagnostics into the observation (P1-4).
        edited_paths =
          for {:valid, _dp, ep, _o, _n, _c, _nc} <- validation_results, do: ep

        Enum.each(edited_paths, &FileState.record_write(session, &1))

        # Move the drift-guard baseline to the content this batch just wrote,
        # so a follow-up edit in the same session is not falsely flagged.
        Enum.each(applied, fn {ep, new_content} ->
          {mtime, size} = stat_or_zero(ep)
          DriftGuard.record(session, ep, new_content, mtime, size)
        end)

        hook_note =
          edited_paths
          |> Enum.map(fn ep ->
            note =
              FileEditHandler.file_changed_note(%{
                path: ep,
                tool: "multi_file_edit",
                operation: :edit
              })

            # A :file_changed formatter hook may have rewritten this path;
            # re-capture its baseline from the final on-disk bytes so a
            # follow-up edit isn't falsely flagged stale.
            FileEditHandler.refresh_write_baseline(session, ep)
            note
          end)
          |> Enum.join("")

        summary =
          Enum.map_join(per_file, "\n", fn %{path: dp, lines_changed: lc} ->
            "  #{dp} (#{lc} lines changed)"
          end)

        # Per-hunk outcomes: the skipped hunks are named explicitly so the
        # model can tell "already in the requested state" apart from "silently
        # dropped".
        skipped =
          if already_applied == [] do
            ""
          else
            "\n" <> Enum.map_join(already_applied, "\n", &"  #{&1} (already applied, skipped)")
          end

        count = length(per_file)

        result =
          "Edited #{count} #{if count == 1, do: "file", else: "files"}:\n" <>
            summary <> skipped <> hook_note

        {:ok, result, %{results: per_file, count: count, already_applied: already_applied}}

      {:error, reason} ->
        # The rollback outcome is stated by `commit_all/1`, which knows whether
        # the restore actually succeeded. This wrapper no longer asserts
        # "no files were modified" on its behalf.
        {:error, "Apply failed:\n  #{reason}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  defp resolve_edit(%{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded = resolve_path(path)
    %{display_path: path, expanded_path: expanded, old_string: old, new_string: new}
  end

  defp resolve_edit(edit), do: {:invalid, inspect(edit)}

  defp validate_edit({:invalid, raw}, _session) do
    {:error, raw, "malformed edit (missing path, old_string, or new_string)"}
  end

  defp validate_edit(
         %{display_path: dp, expanded_path: ep, old_string: old, new_string: new},
         session
       ) do
    cond do
      old == "" ->
        {:error, dp, "old_string cannot be empty"}

      old == new ->
        # Mirror the not_found steer (P1-9): a bare "are identical" gives the
        # model no next step, so it retries the same no-op hunk. `dp` is already
        # shown by per_hunk_report, so the reason stays path-free.
        {:error, dp,
         "old_string and new_string are identical - nothing to change; if you intended an edit, " <>
           "re-read the file and copy the exact current text into old_string and the changed text " <>
           "into new_string; if it is already applied, move on rather than retrying"}

      not File.exists?(ep) ->
        {:error, dp, "file not found"}

      true ->
        case File.read(ep) do
          {:ok, content} ->
            # Match with the SAME fuzzy cascade `file_edit` uses (exact ->
            # line-endings -> whitespace -> deep fuzzy). Previously this tool
            # matched with an exact `String.contains?/2` only, so an edit with
            # trivial whitespace/line-ending drift failed here — then fell into
            # the idempotency branch and, if `new_string` happened to be
            # present, reported a FALSE "already applied" success while the same
            # edit succeeded in `file_edit`. Unifying the matcher removes that
            # divergence at the root.
            case Matcher.replace(content, old, new, false) do
              {:ok, new_content, _count, _stage} ->
                # Read-before-edit / stale-write guard (P0-1). Any un-read or
                # stale target fails the whole batch — no files modified.
                {mtime, size} = stat_or_zero(ep)

                with :ok <- FileState.check_read(session, ep),
                     :ok <- DriftGuard.verify(session, ep, content, mtime, size) do
                  {:valid, dp, ep, old, new, content, new_content}
                else
                  {:error, msg} -> {:error, dp, msg}
                end

              {:error, :ambiguous, count} ->
                {:error, dp,
                 "old_string found multiple times (#{count}) — must be unique; " <>
                   "add surrounding context"}

              {:error, :disproportionate} ->
                {:error, dp,
                 "old_string matched only approximately and the resulting change is " <>
                   "disproportionate — re-read the file and copy old_string verbatim"}

              {:error, {:replace_all_approximate, _}} ->
                {:error, dp,
                 "old_string matched only approximately — copy it verbatim and retry"}

              {:error, :not_found} ->
                # Genuinely absent even after fuzzy matching, so the idempotency
                # check is now meaningful: old_string is really gone. Narrow,
                # exactly as in `file_edit`: `new` must be non-empty AND present.
                # A deletion (`new == ""`) is vacuously present, so it keeps the
                # hard error rather than being swallowed.
                if new != "" and String.contains?(content, new) do
                  {:already_applied, dp}
                else
                  {:error, dp, "old_string not found in file"}
                end
            end

          {:error, reason} ->
            {:error, dp, "cannot read file: #{reason}"}
        end
    end
  end

  # POSIX {mtime, size} for DriftGuard. A stat failure degrades to {0, 0},
  # which DriftGuard treats as a non-matching identity and defers on — never a
  # false rejection. Mirrors `FileEdit.Handler.stat_or_zero/1`.
  defp stat_or_zero(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      _ -> {0, 0}
    end
  end

  # POSIX {mtime, size} for DriftGuard, identical to `FileEdit.Handler`'s. A
  # stat failure degrades to {0, 0}, which DriftGuard treats as a non-matching
  # identity and simply defers on — never a false rejection.
  defp stat_or_zero(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      _ -> {0, 0}
    end
  end

  # Apply every validated edit as a batch: all files change or none do.
  #
  # Two phases:
  #   1. PRECHECK — confirm every target is actually writable, WITHOUT creating
  #                 or modifying anything. A permission problem therefore aborts
  #                 with zero files touched.
  #   2. COMMIT   — write each file in place. On failure partway, restore the
  #                 targets already written from their in-memory originals.
  #
  # ## Why not stage-to-temp-then-rename
  #
  # The previous implementation wrote each new content to a sibling
  # `<target>.osa-tmp-<n>` and `File.rename`d it over the target. `rename(2)`
  # replaces the directory entry, so the target's INODE is swapped for a fresh
  # one created by `File.write` at the default 0644. That silently destroyed,
  # on every single edit:
  #
  #   * the execute bit — editing a `chmod +x` script left it non-executable;
  #   * owner/group, ACLs and xattrs;
  #   * every hard link to the file — the other names kept the OLD content;
  #   * and worst, a SYMLINK target: renaming over a symlink deletes the link
  #     and leaves a regular file in its place, so the file the link pointed at
  #     was never updated at all and the link is gone.
  #
  # The temp files were also predictable, created inside the user's own repo,
  # and only removed on the explicit failure branches — a crash or a kill mid
  # batch left `foo.ex.osa-tmp-37` behind for compilers, watchers and
  # `git status` to trip over, with no sweeper anywhere.
  #
  # Writing in place keeps the inode, so every one of those properties
  # survives; it is also exactly what `file_edit` and `file_write` already do.
  # The all-or-nothing guarantee never came from `rename` anyway — it is a
  # batch property, provided by the rollback below.
  defp apply_atomic(validation_results) do
    edits =
      Enum.map(validation_results, fn
        {:valid, display_path, expanded_path, old, _new, content, new_content} ->
          %{
            display_path: display_path,
            expanded_path: expanded_path,
            content: content,
            new_content: new_content,
            lines_changed: old |> String.split("\n") |> length()
          }
      end)

    case precheck_all(edits) do
      :ok -> commit_all(edits)
      {:error, reason} -> {:error, reason}
    end
  end

  # Phase 1 — confirm each target can be opened for writing. `:append` is used
  # deliberately: unlike `:write` it does NOT truncate, so a precheck can never
  # damage a file it is only asking about, and nothing is written because the
  # handle is closed immediately.
  defp precheck_all(edits) do
    Enum.reduce_while(edits, :ok, fn edit, :ok ->
      case File.open(edit.expanded_path, [:append]) do
        {:ok, io} ->
          File.close(io)
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            "#{edit.display_path}: not writable (#{:file.format_error(reason)}) — " <>
              "no files were modified"}}
      end
    end)
  end

  # Phase 2 — write each file in place. On any failure, restore every target
  # already written from its in-memory original.
  defp commit_all(edits) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, committed} ->
      case File.write(edit.expanded_path, edit.new_content) do
        :ok ->
          result = %{path: edit.display_path, lines_changed: edit.lines_changed}
          {:cont, {:ok, [{edit, result} | committed]}}

        {:error, reason} ->
          failed = rollback(committed)
          {:halt, {:error, failure_message(edit, reason, failed)}}
      end
    end)
    |> case do
      {:ok, committed} ->
        ordered = Enum.reverse(committed)
        per_file = Enum.map(ordered, &elem(&1, 1))
        # {expanded_path, new_content} pairs, so the caller can refresh the
        # drift-guard baseline to what THIS batch actually wrote. The public
        # `per_file` shape is left exactly as it was for SSE/TUI consumers.
        applied = Enum.map(ordered, fn {edit, _} -> {edit.expanded_path, edit.new_content} end)
        {:ok, per_file, applied}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The restore is itself I/O and can itself fail — the disk that just refused
  # a write is exactly the disk being asked to accept one. `rollback/1` used to
  # be `Enum.each(... File.write ...)` with every result discarded, and the
  # caller then reported "all changes rolled back, no files were modified"
  # unconditionally. When a restore failed, that sentence was simply false and
  # the model had no way to learn which files were left rewritten.
  #
  # Returns the paths that could NOT be restored.
  defp rollback(committed) do
    committed
    |> Enum.filter(fn {edit, _result} ->
      File.write(edit.expanded_path, edit.content) != :ok
    end)
    |> Enum.map(fn {edit, _result} -> edit.display_path end)
  end

  defp failure_message(edit, reason, []) do
    "#{edit.display_path}: write failed (#{:file.format_error(reason)}) — " <>
      "every file already written was restored, so no files were modified."
  end

  defp failure_message(edit, reason, unrestored) do
    "#{edit.display_path}: write failed (#{:file.format_error(reason)}). " <>
      "ROLLBACK INCOMPLETE — these files were rewritten and could NOT be restored: " <>
      Enum.join(unrestored, ", ") <>
      ". They hold the NEW content while the batch as a whole did not apply. " <>
      "Re-read them before doing anything else."
  end

  # A bare relative path means the agent's workspace, matching `file_write`.
  defp normalize_path(path) do
    if relative_path?(path), do: Path.join("~/.osa/workspace", path), else: path
  end

  # CANONICAL target. Resolving the whole chain here is not only the security
  # check — it is also what makes an edit to a symlinked file land on the real
  # file instead of replacing the link.
  defp resolve_path(path), do: path |> normalize_path() |> PathPolicy.canonical()

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end
end
