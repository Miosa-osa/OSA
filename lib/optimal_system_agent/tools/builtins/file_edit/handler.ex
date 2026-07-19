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

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Constants
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
    expanded = Path.expand(path)
    resolved = resolve_real_path(expanded)
    symlink_traversal? = resolved != expanded

    cond do
      symlink_traversal? and
          (not read_allowed?(resolved) or not write_allowed?(resolved)) ->
        {:deny, "Access denied: #{path} resolves through a symlink to a protected location"}

      not read_allowed?(resolved) ->
        {:deny, "Access denied: #{path} is outside allowed paths or is a sensitive file"}

      not write_allowed?(resolved) ->
        {:deny, "Access denied: #{path} targets a protected location"}

      true ->
        {:allow, input}
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
        do_edit(resolved, path, old, new, replace_all, session_id(ctx))
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
        case FileState.check_read(session, expanded) do
          {:error, msg} -> {:error, msg}
          :ok -> do_edit_apply(expanded, display_path, old, new, replace_all, content, session)
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
        {:error, "old_string not found in #{display_path}"}

      {:error, :ambiguous, count} ->
        {:error,
         "old_string found #{count} times — must be unique. Add more surrounding context or use replace_all."}

      {:error, :disproportionate} ->
        {:error,
         "Refusing edit in #{display_path}: the fuzzy-matched region is much larger than old_string. " <>
           "Re-read the file and provide the exact text to replace."}

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

            # Generate unified diff (delegates to Utils.Diff for proper unified format)
            {diff_text, diff_stats} =
              OptimalSystemAgent.Utils.Diff.unified(content, new_content, display_path)

            fuzzy_note = if stage == :exact, do: "", else: " (fuzzy #{stage} match)"

            base_result =
              if replace_all and occurrences > 1 do
                "Replaced #{occurrences} occurrences in #{display_path}#{fuzzy_note}"
              else
                "Replaced in #{display_path}#{fuzzy_note}\n#{format_diff(old, new, content, display_path)}"
              end

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

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  # Run the :file_changed validation hook SYNCHRONOUSLY and turn any reported
  # failure (a compile/lint diagnostic on the edited file) into a note appended
  # to the tool observation, so the model self-corrects in the same turn (P1-4).
  #
  # Returns "" when the hook reports nothing (the common case: no post-edit
  # validation hook registered). Always non-fatal — never raises into the caller.
  @spec file_changed_note(map()) :: String.t()
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

  # Build a minimal unified diff showing the change with context lines.
  # Kept identical to the original implementation — callers depend on the exact
  # output format.
  defp format_diff(old, new, content, path) do
    lines = String.split(content, "\n")
    old_lines = String.split(old, "\n")
    first_old_line = List.first(old_lines) || ""

    # Find the line number where the match starts
    start_idx = Enum.find_index(lines, fn l -> String.contains?(l, first_old_line) end) || 0

    # Context: 2 lines before and after
    ctx_before = Enum.slice(lines, max(start_idx - 2, 0), min(2, start_idx))
    ctx_after = Enum.slice(lines, start_idx + length(old_lines), 2)

    removed = old_lines |> Enum.map(fn l -> "- #{l}" end)
    added = String.split(new, "\n") |> Enum.map(fn l -> "+ #{l}" end)
    context_b = ctx_before |> Enum.map(fn l -> "  #{l}" end)
    context_a = ctx_after |> Enum.map(fn l -> "  #{l}" end)

    header = "--- #{path}\n+++ #{path}"
    hunk = "@@ -#{max(start_idx - 1, 1)},#{length(old_lines) + 4} @@"

    diff_lines = [header, hunk] ++ context_b ++ removed ++ added ++ context_a
    Enum.join(diff_lines, "\n")
  end

  # Resolve symlinks BEFORE security checks to prevent symlink traversal attacks.
  # Uses :file.read_link_all which follows the full symlink chain (POSIX realpath).
  # Falls back to the original path if the path doesn't exist or has no symlinks.
  defp resolve_real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real} ->
        real_str = to_string(real)
        if String.starts_with?(real_str, "/"), do: real_str, else: "/" <> real_str

      {:error, :einval} ->
        path

      {:error, _} ->
        path
    end
  end

  defp read_allowed?(expanded_path) do
    sensitive =
      Enum.any?(Constants.sensitive_paths(), fn p -> String.contains?(expanded_path, p) end)

    if sensitive do
      false
    else
      check =
        if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

      Enum.any?(allowed_read_paths(), fn a -> String.starts_with?(check, a) end)
    end
  end

  defp write_allowed?(expanded_path) do
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked =
        Enum.any?(Constants.blocked_write_paths(), fn p ->
          String.contains?(expanded_path, p)
        end)

      if blocked do
        false
      else
        check =
          if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

        Enum.any?(allowed_write_paths(), fn a -> String.starts_with?(check, a) end)
      end
    end
  end

  defp allowed_read_paths do
    Application.get_env(
      :optimal_system_agent,
      :allowed_read_paths,
      Constants.default_allowed_paths()
    )
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp allowed_write_paths do
    Application.get_env(
      :optimal_system_agent,
      :allowed_write_paths,
      Constants.default_allowed_paths()
    )
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")
    osa = Path.expand("~/.osa") <> "/"

    case String.split_at(expanded_path, byte_size(home)) do
      {^home, "/" <> rest} ->
        first = rest |> String.split("/") |> List.first()
        String.starts_with?(first, ".") and not String.starts_with?(expanded_path, osa)

      _ ->
        false
    end
  end
end
