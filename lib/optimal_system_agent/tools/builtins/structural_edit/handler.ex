defmodule OptimalSystemAgent.Tools.Builtins.StructuralEdit.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `structural_edit` (H1: a
  safe structural / multi-file edit tool, so the model has an anchored,
  all-or-reports alternative to hand-rolling a regex sweep across files).

  ## Two input shapes, mergeable

    * `"pattern"` — `%{"old_string" => _, "new_string" => _, "paths" => [_]}`.
      ONE anchored edit, replicated across every path in `paths`. This is the
      genuinely new affordance: "rename X to Y in these 6 files" without
      repeating identical `old_string`/`new_string` six times.
    * `"edits"` — `[%{"path" => _, "old_string" => _, "new_string" => _}, ...]`.
      Heterogeneous per-file edits, same shape `multi_file_edit` accepts.

  Both may be given together; they are concatenated into one target set.

  ## Pipeline

    * `validate/2`          — type-checks input shape (cheap)
    * `check_permissions/2` — path allowlist check on every resolved target
    * `execute/2`           — classify every target, then apply-all-or-report

  ## Classification (per target, before anything is written)

  Every target is matched with the SAME anchored/exact cascade `file_edit`
  uses (`FileEdit.Matcher` — exact, then line-ending/whitespace fuzzy stages),
  never free-form regex, and classified into exactly one status:

    * `:applied`         — matched exactly once; would apply cleanly.
    * `:already_applied` — `old_string` is absent but `new_string` is already
                            present — idempotent no-op, not an error.
    * `:no_match`         — `old_string` is not present at all.
    * `:conflict`         — `old_string` matches more than once (or only an
                            approximate/disproportionate fuzzy candidate was
                            found) — never silently picks one.
    * `:missing`          — the file does not exist.
    * `:blocked`          — read-before-edit / drift-guard rejected it (the
                            file was never read this session, or changed on
                            disk since).
    * `:invalid`          — malformed edit spec (empty or identical strings).

  ## All-or-reports

  If every target classifies as `:applied` or `:already_applied`, the
  `:applied` set is written ATOMICALLY (precheck every target is writable
  before touching any of them; on a write failure partway through, every file
  already written is restored from its in-memory original) — mirrors
  `MultiFileEdit.Handler.apply_atomic/1`, reimplemented here rather than
  reused so this tool stays self-contained.

  If ANY target does not classify cleanly, NOTHING is written. The error
  carries the outcome of every single target — including the ones that would
  have applied — so the model can fix exactly the one that failed and reissue
  the same call rather than re-deriving the whole batch.

  ## Optional verify

  `"verify" => true` runs `OptimalSystemAgent.Verify.PostEdit.run/2` (the same
  fast, in-process, dependency-light syntax/format check `file_edit`'s
  post-edit diagnostics hook uses) on every file this call actually wrote, and
  folds any findings into the result. Advisory only: it never undoes a
  successful apply.
  """

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEditHandler
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Verify.PostEdit

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input) do
    edits = Map.get(input, "edits")
    pattern = Map.get(input, "pattern")

    cond do
      is_nil(edits) and is_nil(pattern) ->
        {:error,
         "Provide `edits` (a list of per-file edits) or `pattern` (one edit applied " <>
           "to a set of files)", -32_602}

      not is_nil(edits) and not valid_edits?(edits) ->
        {:error,
         "edits must be a non-empty list of {path, old_string, new_string} objects (all strings)",
         -32_602}

      not is_nil(pattern) and not valid_pattern?(pattern) ->
        {:error,
         "pattern must be {old_string, new_string, paths} — old_string/new_string strings, " <>
           "paths a non-empty list of strings", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(_, _ctx), do: {:error, "Input must be a map", -32_602}

  defp valid_edits?(edits) do
    is_list(edits) and edits != [] and Enum.all?(edits, &valid_edit_shape?/1)
  end

  defp valid_edit_shape?(%{"path" => p, "old_string" => o, "new_string" => n}),
    do: is_binary(p) and is_binary(o) and is_binary(n)

  defp valid_edit_shape?(_), do: false

  defp valid_pattern?(%{"old_string" => o, "new_string" => n, "paths" => paths})
       when is_binary(o) and is_binary(n) and is_list(paths) and paths != [],
       do: Enum.all?(paths, &is_binary/1)

  defp valid_pattern?(_), do: false

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx) when is_map(input) do
    # The SAME write decision every write tool uses (`PathPolicy.check_write/2`)
    # — see `MultiFileEdit.Handler.check_permissions/2`, whose comment explains
    # why a tool-local reimplementation of this check is exactly the bug this
    # tool must not repeat.
    denied =
      input
      |> all_target_paths()
      |> Enum.find_value(fn path ->
        case PathPolicy.check_write(normalize_path(path), path) do
          :ok -> nil
          {:deny, reason} -> reason
        end
      end)

    if denied, do: {:deny, denied}, else: {:allow, input}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  @doc """
  Every path this call targets (`edits` ++ `pattern.paths`), in display form.

  Deliberately LENIENT — unlike `specs/1` (which feeds classification and
  requires the full `old_string`/`new_string` shape), this only requires a
  non-empty `"path"` string per edit / a list of path strings under
  `pattern.paths`. It backs shared safety-net callers (`PathPolicy` scope
  checks here, plus `Permissions`, `ConflictScope`, and
  `FSCheckpoint.Hook` outside this module) that must see every plausible
  target — including one from a malformed edit — rather than silently drop a
  path because ONE other field on its edit happened to be missing.
  """
  @spec all_target_paths(map()) :: [String.t()]
  def all_target_paths(input) when is_map(input) do
    from_edits =
      case Map.get(input, "edits") do
        list when is_list(list) ->
          Enum.flat_map(list, fn
            %{"path" => p} when is_binary(p) and p != "" -> [p]
            _ -> []
          end)

        _ ->
          []
      end

    from_pattern =
      case Map.get(input, "pattern") do
        %{"paths" => paths} when is_list(paths) ->
          Enum.filter(paths, &(is_binary(&1) and &1 != ""))

        _ ->
          []
      end

    from_edits ++ from_pattern
  end

  def all_target_paths(_), do: []

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t(), map()} | {:error, String.t()}
  def execute(input, ctx) when is_map(input) do
    session = session_id(ctx)
    verify? = Map.get(input, "verify") == true

    case specs(input) do
      [] ->
        {:error, "Provide `edits` or `pattern` — nothing to do"}

      raw_specs ->
        classified =
          raw_specs
          |> Enum.map(&resolve_spec/1)
          |> Enum.map(&classify(&1, session))

        clean? = Enum.all?(classified, &(&1.status in [:applied, :already_applied]))

        cond do
          not clean? ->
            {:error,
             "Nothing applied — one or more targets did not resolve cleanly:\n" <>
               report(classified)}

          Enum.all?(classified, &(&1.status == :already_applied)) ->
            count = length(classified)

            {:ok,
             "No changes needed — all #{count} #{plural(count, "target")} already " <>
               "match the requested state:\n" <>
               report(classified) <>
               "\nThe files are in the requested state — continue with the next step " <>
               "rather than retrying.", %{results: [], count: 0}}

          true ->
            apply_all(classified, session, verify?)
        end
    end
  end

  def execute(_, _ctx), do: {:error, "Input must be a map"}

  # ── Building the target set ────────────────────────────────────────────

  # Robust to being called before `validate/2` has run (e.g. from
  # `to_classifier_input/1`) — malformed entries are skipped rather than
  # raising.
  defp specs(input) when is_map(input) do
    from_edits =
      case Map.get(input, "edits") do
        list when is_list(list) ->
          Enum.flat_map(list, fn
            %{"path" => p, "old_string" => o, "new_string" => n}
            when is_binary(p) and is_binary(o) and is_binary(n) ->
              [%{display_path: p, old_string: o, new_string: n}]

            _ ->
              []
          end)

        _ ->
          []
      end

    from_pattern =
      case Map.get(input, "pattern") do
        %{"old_string" => o, "new_string" => n, "paths" => paths}
        when is_binary(o) and is_binary(n) and is_list(paths) ->
          Enum.flat_map(paths, fn
            p when is_binary(p) -> [%{display_path: p, old_string: o, new_string: n}]
            _ -> []
          end)

        _ ->
          []
      end

    from_edits ++ from_pattern
  end

  defp specs(_), do: []

  defp resolve_spec(%{display_path: dp, old_string: old, new_string: new}) do
    %{display_path: dp, expanded_path: resolve_path(dp), old_string: old, new_string: new}
  end

  # ── Classification (read-only — nothing is written here) ──────────────

  defp classify(spec, session) do
    %{expanded_path: ep, old_string: old, new_string: new} = spec

    cond do
      old == "" ->
        base(spec, :invalid, "old_string cannot be empty")

      old == new ->
        base(spec, :invalid, "old_string and new_string are identical — nothing to change")

      not File.exists?(ep) ->
        base(spec, :missing, "file not found")

      true ->
        case File.read(ep) do
          {:ok, content} -> classify_content(spec, content, session)
          {:error, reason} -> base(spec, :blocked, "cannot read file: #{reason}")
        end
    end
  end

  defp classify_content(spec, content, session) do
    %{expanded_path: ep, old_string: old, new_string: new} = spec

    case Matcher.replace(content, old, new, false) do
      {:ok, new_content, _count, _stage} ->
        # Read-before-edit / stale-write guard, and the independent
        # content-hash drift guard on top of it — the SAME two checks
        # `file_edit` and `multi_file_edit` run before committing a write.
        {mtime, size} = stat_or_zero(ep)

        with :ok <- FileState.check_read(session, ep),
             :ok <- DriftGuard.verify(session, ep, content, mtime, size) do
          spec
          |> base(:applied, nil)
          |> Map.merge(%{content: content, new_content: new_content})
        else
          {:error, msg} -> base(spec, :blocked, msg)
        end

      {:error, :ambiguous, count} ->
        base(spec, :conflict, "old_string matched #{count} times — must be unique")

      {:error, :disproportionate} ->
        base(spec, :conflict, "fuzzy match was too approximate to trust")

      {:error, {:replace_all_approximate, _}} ->
        base(spec, :conflict, "only an approximate match was found")

      {:error, :not_found} ->
        # Idempotent retry (mirrors `file_edit`/`multi_file_edit`): `old_string`
        # genuinely absent AND `new_string` already present means this target
        # already holds the requested state — narrower than "ignore missing
        # matches" because a deletion (`new == ""`) is vacuously present and
        # keeps the hard `:no_match`.
        if new != "" and String.contains?(content, new) do
          base(spec, :already_applied, nil)
        else
          base(spec, :no_match, "old_string not found")
        end
    end
  end

  defp base(spec, status, reason) do
    spec
    |> Map.take([:display_path, :expanded_path, :old_string, :new_string])
    |> Map.merge(%{status: status, reason: reason})
  end

  # ── Reporting ───────────────────────────────────────────────────────────

  defp report(classified) do
    Enum.map_join(classified, "\n", fn %{display_path: dp, status: s, reason: r} ->
      base = "  - #{dp}: #{status_text(s)}"
      if r, do: base <> " (#{r})", else: base
    end)
  end

  defp status_text(:applied), do: "applied (would apply cleanly)"
  defp status_text(:already_applied), do: "already_applied"
  defp status_text(:no_match), do: "no_match"
  defp status_text(:conflict), do: "conflict"
  defp status_text(:missing), do: "missing"
  defp status_text(:blocked), do: "blocked"
  defp status_text(:invalid), do: "invalid"

  # ── Apply (all-or-nothing over the classified :applied set) ───────────

  defp apply_all(classified, session, verify?) do
    to_write = Enum.filter(classified, &(&1.status == :applied))
    already = Enum.filter(classified, &(&1.status == :already_applied))

    case atomic_write(to_write) do
      {:ok, committed} ->
        Enum.each(committed, fn c -> FileState.record_write(session, c.expanded_path) end)

        Enum.each(committed, fn c ->
          {mtime, size} = stat_or_zero(c.expanded_path)
          DriftGuard.record(session, c.expanded_path, c.new_content, mtime, size)
        end)

        # Same `:file_changed` validation hook the other write tools run
        # synchronously post-write, reused (not reimplemented) via
        # `FileEditHandler`'s public API.
        hook_notes =
          committed
          |> Enum.map(fn c ->
            note =
              FileEditHandler.file_changed_note(%{
                path: c.expanded_path,
                tool: "structural_edit",
                operation: :edit
              })

            FileEditHandler.refresh_write_baseline(session, c.expanded_path)
            note
          end)
          |> Enum.join("")

        verify_note = if verify?, do: verify_note(committed), else: ""

        summary =
          Enum.map_join(committed, "\n", fn c ->
            "  applied: #{c.display_path} (#{c.lines_changed} lines changed)"
          end)

        already_lines =
          if already == [] do
            ""
          else
            "\n" <> Enum.map_join(already, "\n", &"  already_applied: #{&1.display_path}")
          end

        count = length(committed)

        result =
          "Applied #{count} #{plural(count, "edit")}:\n" <>
            summary <> already_lines <> hook_notes <> verify_note

        {:ok, result,
         %{
           results:
             Enum.map(committed, &%{path: &1.display_path, lines_changed: &1.lines_changed}),
           count: count
         }}

      {:error, reason} ->
        {:error, "Apply failed:\n  #{reason}"}
    end
  end

  defp verify_note(committed) do
    diagnostics =
      committed
      |> Enum.map(fn c -> {c.display_path, safe_verify(c.expanded_path)} end)
      |> Enum.reject(fn {_p, d} -> d == "" end)

    case diagnostics do
      [] ->
        "\n\nVerification: no issues found in #{length(committed)} touched " <>
          "#{plural(length(committed), "file")}."

      list ->
        body =
          Enum.map_join(list, "\n", fn {p, d} -> "  #{p}:\n#{indent(d)}" end)

        "\n\nVerification found issues — fix before continuing:\n" <> body
    end
  end

  defp safe_verify(path) do
    PostEdit.run(path, %{})
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &"    #{&1}")

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  # ── Atomic write (precheck-then-commit, with rollback on partial failure)
  #
  # Reimplemented from `MultiFileEdit.Handler.apply_atomic/1` rather than
  # called into (this tool stays self-contained; see moduledoc). Same
  # in-place-write rationale: writing in place (not stage-to-temp-then-rename)
  # preserves inode identity — execute bit, hard links, and symlink targets —
  # which a rename-over-target would silently destroy.

  defp atomic_write(to_write) do
    edits =
      Enum.map(to_write, fn c ->
        %{
          display_path: c.display_path,
          expanded_path: c.expanded_path,
          content: c.content,
          new_content: c.new_content,
          lines_changed: c.old_string |> String.split("\n") |> length()
        }
      end)

    case precheck_all(edits) do
      :ok -> commit_all(edits)
      {:error, reason} -> {:error, reason}
    end
  end

  # Phase 1 — confirm every target is writable WITHOUT creating or modifying
  # anything (`:append` never truncates, and the handle is closed immediately).
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
          {:cont, {:ok, [edit | committed]}}

        {:error, reason} ->
          failed = rollback(committed)
          {:halt, {:error, failure_message(edit, reason, failed)}}
      end
    end)
    |> case do
      {:ok, committed} -> {:ok, Enum.reverse(committed)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Returns the paths that could NOT be restored — the restore is itself I/O
  # and can itself fail.
  defp rollback(committed) do
    committed
    |> Enum.filter(fn edit -> File.write(edit.expanded_path, edit.content) != :ok end)
    |> Enum.map(& &1.display_path)
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

  # ── Private ───────────────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  defp stat_or_zero(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {mtime, size}
      _ -> {0, 0}
    end
  end

  # A bare relative path means the agent's workspace, matching
  # `file_write`/`multi_file_edit`.
  defp normalize_path(path) do
    if relative_path?(path), do: Path.join("~/.osa/workspace", path), else: path
  end

  # CANONICAL target — resolving the whole symlink chain here is both the
  # security check and what makes an edit to a symlinked file land on the
  # real file instead of replacing the link.
  defp resolve_path(path), do: path |> normalize_path() |> PathPolicy.canonical()

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end
end
