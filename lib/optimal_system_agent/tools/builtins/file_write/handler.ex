defmodule OptimalSystemAgent.Tools.Builtins.FileWrite.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_write`.

  Behaviour split mirrors the the contract:
    * `validate/2`           — type-checks input shape (cheap, no I/O)
    * `check_permissions/2`  — path allowlist + blocked-path deny
    * `execute/2`            — actual file write with diff generation and hook emission

  Logic was moved verbatim from the original `file_write.ex`. No semantic changes
  in Phase 3b — just relocation + permission/validation split.

  ## Edge cases preserved
    * Symlink traversal detection via `resolve_for_write/1`
    * Dotfiles outside `~/.osa/` are blocked
    * Soul cache reload on writes to `~/.osa/USER.md`, `IDENTITY.md`, `SOUL.md`
    * `file_changed` hook emission (async, fire-and-forget, errors swallowed)
    * Rich `{:ok, result, metadata}` return with diff text + stats when content changes
  """

  alias OptimalSystemAgent.Agent.Safety.PathCanon
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEditHandler
  alias OptimalSystemAgent.Tools.Builtins.FileWrite.Constants
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path, "content" => content} = input, _ctx)
      when is_binary(path) and is_binary(content),
      do: {:ok, input}

  def validate(%{"path" => _, "content" => _}, _ctx),
    do: {:error, "path and content must be strings", -32_602}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "Missing required parameter: content", -32_602}

  def validate(%{"content" => _}, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: path, content", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    normalized =
      if relative_path?(path),
        do: Path.join("~/.osa/workspace", path),
        else: path

    expanded = Path.expand(normalized)
    {resolved, symlink_traversal?} = resolve_for_write(expanded)

    cond do
      # Guard on the *pre-resolution* path: a protected dotfile (e.g. ~/.zshrc)
      # is protected by its name/location, even when it is a symlink pointing
      # into an otherwise-allowed directory. Without this, symlinked dotfiles
      # silently bypass the dotfile deny (the resolved target is not a dotfile).
      dotfile_outside_osa?(expanded) ->
        {:deny, "Access denied: #{path} is a protected dotfile outside ~/.osa/"}

      symlink_traversal? and not write_allowed?(resolved) ->
        {:deny, "Access denied: #{path} resolves through a symlink to a protected location"}

      not write_allowed?(resolved) ->
        {:deny, "Access denied: #{path} is outside allowed paths or targets a protected location"}

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()}
          | {:ok, String.t(), map()}
          | {:error, String.t()}
  def execute(%{"path" => path, "content" => content}, ctx) do
    normalized =
      if relative_path?(path),
        do: Path.join("~/.osa/workspace", path),
        else: path

    expanded = Path.expand(normalized)

    # Defense-in-depth: re-run the permission guard here so the security
    # property holds even when execute/2 is invoked directly (bypassing the
    # LegacyAdapter validate → check_permissions → execute pipeline). Mirrors
    # check_permissions/2 exactly and fails closed.
    case execute_guard(path, expanded) do
      :allow -> do_execute(path, content, expanded, session_id(ctx))
      {:deny, msg} -> {:error, msg}
    end
  end

  defp execute_guard(orig_path, expanded) do
    {resolved, symlink_traversal?} = resolve_for_write(expanded)

    cond do
      dotfile_outside_osa?(expanded) ->
        {:deny, "Access denied: #{orig_path} is a protected dotfile outside ~/.osa/"}

      symlink_traversal? and not write_allowed?(resolved) ->
        {:deny, "Access denied: #{orig_path} resolves through a symlink to a protected location"}

      not write_allowed?(resolved) ->
        {:deny, "Access denied: #{orig_path} is outside allowed paths or targets a protected location"}

      true ->
        :allow
    end
  end

  defp do_execute(path, content, expanded, session) do
    # Read existing content for diff generation (if file exists)
    old_content =
      case File.read(expanded) do
        {:ok, existing} -> existing
        {:error, _} -> nil
      end

    # Read-before-overwrite (P0-1): overwriting an EXISTING file requires it was
    # read this session and hasn't changed since. Creating a NEW file (old_content
    # == nil) is always allowed — there is nothing to clobber.
    read_guard =
      if is_nil(old_content), do: :ok, else: FileState.check_read(session, expanded)

    case read_guard do
      {:error, msg} -> {:error, msg}
      :ok -> do_write(path, content, expanded, old_content, session)
    end
  end

  defp do_write(path, content, expanded, old_content, session) do
    case File.mkdir_p(Path.dirname(expanded)) do
      :ok ->
        case File.write(expanded, content) do
          :ok ->
            # Reload Soul cache when agent writes to ~/.osa/ identity/personality files
            maybe_reload_soul(expanded)

            operation = if old_content, do: :overwrite, else: :create

            # Refresh read-state to the just-written file so a follow-up edit in
            # the same turn is not falsely flagged stale, and so a freshly-created
            # file counts as "read" for subsequent edits (P0-1).
            FileState.record_write(session, expanded)

            # Post-write validation hook (P1-4): run SYNCHRONOUSLY and surface any
            # compile/lint failure on the written file into this observation, same
            # turn. Non-fatal — the write already landed. Reuses FileEdit's helper.
            hook_note =
              FileEditHandler.file_changed_note(%{
                path: expanded,
                tool: "file_write",
                operation: operation
              })

            line_count = content |> String.split("\n") |> length()
            preview = content |> String.split("\n") |> Enum.take(10) |> Enum.join("\n")

            # Generate diff for event payload
            {diff_text, diff_stats} =
              case old_content do
                nil ->
                  OptimalSystemAgent.Utils.Diff.for_new_file(content, path)

                old when old == content ->
                  {"", %{additions: 0, deletions: 0}}

                old ->
                  OptimalSystemAgent.Utils.Diff.unified(old, content, path)
              end

            result = "#{expanded}\n#{line_count} lines written\n---\n#{preview}" <> hook_note

            # Attach diff metadata for SSE consumers
            if diff_text != "" do
              {:ok, result, %{diff: diff_text, stats: diff_stats, path: expanded}}
            else
              {:ok, result}
            end

          {:error, reason} ->
            {:error, write_failure(expanded, reason)}
        end

      {:error, reason} ->
        {:error, mkdir_failure(Path.dirname(expanded), reason)}
    end
  end

  # ── Failure text ──────────────────────────────────────────────────────
  #
  # These used to render as `Error writing file: eacces` — a bare errno, which
  # names neither the cause in words nor anything the caller can do next, so the
  # only available move was to reissue the identical write. Each branch below
  # states the specific fact that stopped the write and one concrete next step,
  # matching the contract `FileRead.Messages` sets for the read side.

  defp write_failure(path, :eacces) do
    "Cannot write #{path}: permission denied (eacces). The path is inside the allowed " <>
      "write roots, but the filesystem refuses it — the file or its directory is owned by " <>
      "another user or is read-only. Retrying will fail identically. Check with " <>
      "`shell_execute` and `ls -ld #{path} #{Path.dirname(path)}`, or write somewhere you own."
  end

  defp write_failure(path, :eisdir) do
    "Cannot write #{path}: it is an existing directory, not a file. Writing would have to " <>
      "destroy the directory, which `file_write` will not do. Choose a filename inside it " <>
      "(e.g. `#{Path.join(path, "output.txt")}`), or use `dir_list` with " <>
      "`path: \"#{path}\"` to see what is already there."
  end

  defp write_failure(path, :enospc) do
    "Cannot write #{path}: the filesystem is out of space (enospc). Nothing was written " <>
      "and no smaller retry of this same file is guaranteed to fit. Check free space with " <>
      "`shell_execute` and `df -h #{Path.dirname(path)}` before retrying."
  end

  defp write_failure(path, :erofs) do
    "Cannot write #{path}: the filesystem is mounted read-only (erofs). No write to any " <>
      "path on this mount can succeed, so a different filename will not help. Write under " <>
      "a writable root such as `~/.osa/workspace` instead."
  end

  defp write_failure(path, :enametoolong) do
    "Cannot write #{path}: the filename is too long for this filesystem (enametoolong, " <>
      "#{byte_size(Path.basename(path))} bytes in the final component). Shorten the " <>
      "basename and retry."
  end

  defp write_failure(path, reason) do
    "Cannot write #{path}: #{:file.format_error(reason)} (#{inspect(reason)}). This is a " <>
      "filesystem-level failure, so reissuing the same write will fail the same way. Use " <>
      "`shell_execute` with `ls -ld #{Path.dirname(path)}` to inspect the target directory."
  end

  defp mkdir_failure(dir, :eacces) do
    "Cannot create the parent directory #{dir}: permission denied (eacces). The file was " <>
      "NOT written. Retrying will fail identically. Inspect the nearest existing ancestor " <>
      "with `shell_execute` and `ls -ld #{Path.dirname(dir)}`, or write under a directory " <>
      "you own such as `~/.osa/workspace`."
  end

  defp mkdir_failure(dir, :enotdir) do
    "Cannot create the parent directory #{dir}: one of its path components is an existing " <>
      "file, not a directory (enotdir). The file was NOT written. Use `dir_list` walking " <>
      "up from #{Path.dirname(dir)} to find which component is the file, then pick a " <>
      "different path."
  end

  defp mkdir_failure(dir, reason) do
    "Cannot create the parent directory #{dir}: #{:file.format_error(reason)} " <>
      "(#{inspect(reason)}). The file was NOT written. Verify the path with `dir_list` on " <>
      "the nearest existing ancestor before retrying."
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end

  # Resolve symlinks for a write target path.
  # Returns {resolved_path, symlink_traversal?} where symlink_traversal? is
  # true when the resolved path differs from the original expanded path.
  #
  # `PathCanon` resolves EVERY component — including a not-yet-existing leaf,
  # which is the normal case for a write. The previous version special-cased
  # the immediate parent only, so `allowed/link/sub/new.txt` where
  # `link -> ~/.ssh` escaped the allowlist entirely: neither the leaf nor its
  # parent (`sub`) was a symlink, so nothing was resolved.
  defp resolve_for_write(expanded_path), do: PathCanon.resolve(expanded_path)

  defp allowed_write_paths do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :allowed_write_paths,
        Constants.default_allowed_write_paths()
      )

    # Canonicalise the roots too: the candidate path is canonical by the time it
    # reaches `write_allowed?/1`, so a root that is itself a symlink (macOS
    # `/tmp`, a symlinked `$HOME`) would otherwise never match and every write
    # would be denied.
    Enum.map(configured, fn p ->
      expanded = PathCanon.canonicalize(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  defp osa_path do
    Path.expand("~/.osa") <> "/"
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")

    relative =
      case String.split_at(expanded_path, byte_size(home)) do
        {^home, rest} -> rest
        _ -> nil
      end

    case relative do
      "/" <> rest ->
        first_component = rest |> String.split("/") |> List.first()
        starts_with_dot = String.starts_with?(first_component, ".")
        under_osa = String.starts_with?(expanded_path, osa_path())
        starts_with_dot and not under_osa

      _ ->
        false
    end
  end

  defp maybe_reload_soul(expanded_path) do
    osa_dir = Path.expand("~/.osa")
    filename = Path.basename(expanded_path)

    if String.starts_with?(expanded_path, osa_dir) and
         filename in Constants.soul_reload_files() do
      try do
        OptimalSystemAgent.Soul.reload()
      rescue
        _ -> :ok
      end
    end
  end

  defp write_allowed?(expanded_path) do
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked =
        Enum.any?(Constants.blocked_write_paths(), fn pattern ->
          String.contains?(expanded_path, pattern)
        end)

      if blocked do
        false
      else
        check_path =
          if String.ends_with?(expanded_path, "/"),
            do: expanded_path,
            else: expanded_path <> "/"

        Enum.any?(allowed_write_paths(), fn allowed ->
          String.starts_with?(check_path, allowed)
        end)
      end
    end
  end
end
