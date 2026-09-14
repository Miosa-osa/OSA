defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `file_glob`.

  Split mirrors the FileRead.Handler pattern:
    * `validate/2`           — type checks input shape (cheap)
    * `check_permissions/2`  — path allowlist + sensitive-path deny
    * `execute/2`            — actual glob expansion

  Logic is verbatim from the original `file_glob.ex` — no semantic changes.
  """

  alias OptimalSystemAgent.Tools.BoundedCmd
  alias OptimalSystemAgent.Tools.Builtins.FileGlob.{Constants, Messages}
  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Backend, as: FileGrepBackend
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"pattern" => pattern} = input, _ctx) when is_binary(pattern) do
    case Map.get(input, "path") do
      nil -> {:ok, input}
      p when is_binary(p) -> {:ok, input}
      other -> {:error, "path must be a string, got #{inspect(other)}", -32_602}
    end
  end

  def validate(%{"pattern" => _}, _ctx),
    do: {:error, "pattern must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: pattern", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"pattern" => _} = input, _ctx) do
    # Expand against the SESSION's directory, not the OS process cwd.
    #
    # `Path.expand/1` resolves a relative path against `File.cwd!()`, which is
    # wherever the BACKEND booted — so a relative pattern was searched in the
    # daemon's own tree rather than the user's workspace. Measured on a
    # benchmark run AFTER the shell-side cwd fix: 29 tool results across three
    # runs reported `No files matched pattern
    # 'test/units/plugins/strategy/test_linear.py' under
    # /home/miosa/projects/osa/OSA`, affecting 7 of 12 instances.
    #
    # That failure is quiet and expensive: the agent asks for the file it needs,
    # is told it does not exist, and carries on without it.
    #
    # The earlier fix (786ac7b8) re-published the cwd across the Task boundary
    # so `shell_execute` saw it. It did not help here, because these tools never
    # consult the process dictionary at all — they call `Path.expand/1`, which
    # reads the OS cwd directly.
    base = Path.expand(input["path"] || ".", OptimalSystemAgent.Workspace.Cwd.get())

    cond do
      sensitive?(base) ->
        {:deny, "Access denied: #{base} is a sensitive path"}

      not allowed?(base) ->
        {:deny, "Access denied: #{base} is outside allowed paths"}

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"pattern" => pattern} = input, _ctx) do
    # Expand against the SESSION's directory, not the OS process cwd.
    #
    # `Path.expand/1` resolves a relative path against `File.cwd!()`, which is
    # wherever the BACKEND booted — so a relative pattern was searched in the
    # daemon's own tree rather than the user's workspace. Measured on a
    # benchmark run AFTER the shell-side cwd fix: 29 tool results across three
    # runs reported `No files matched pattern
    # 'test/units/plugins/strategy/test_linear.py' under
    # /home/miosa/projects/osa/OSA`, affecting 7 of 12 instances.
    #
    # That failure is quiet and expensive: the agent asks for the file it needs,
    # is told it does not exist, and carries on without it.
    #
    # The earlier fix (786ac7b8) re-published the cwd across the Task boundary
    # so `shell_execute` saw it. It did not help here, because these tools never
    # consult the process dictionary at all — they call `Path.expand/1`, which
    # reads the OS cwd directly.
    base = Path.expand(input["path"] || ".", OptimalSystemAgent.Workspace.Cwd.get())

    # Classify the base BEFORE globbing. `Path.wildcard` returns `[]` for a
    # nonexistent base, an unreadable base and a genuinely unmatched pattern
    # alike; those three need three different next steps, and only a `stat`
    # can tell them apart.
    case File.stat(base) do
      {:ok, %{type: :directory}} -> glob_in(pattern, base)
      {:ok, %{type: :regular}} -> {:error, Messages.base_not_a_directory(base)}
      {:ok, %{type: _other}} -> {:error, Messages.base_not_a_directory(base)}
      {:error, :enoent} -> {:error, Messages.missing_base(base)}
      {:error, reason} -> {:error, Messages.base_unreadable(base, reason)}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp glob_in(pattern, base) do
    max = Constants.max_results()
    filter_git? = not references_noise_dir?(pattern)

    case bounded_wildcard(pattern, base) do
      :timeout ->
        {:ok, walk_timed_out_message(base)}

      {:ok, matched} ->
        all =
          matched
          |> Enum.reject(&sensitive?/1)
          |> Enum.reject(fn p -> filter_git? and in_noise_dir?(p) end)
          |> Enum.sort()

        format_glob_result(all, pattern, base, filter_git?, max)
    end
  end

  # `Path.wildcard/2` walks the WHOLE tree under `base`, FOLLOWS symlinks, and
  # never consults `.gitignore`, so a `**`-rooted pattern over a repo root with a
  # large symlinked `_build`/`deps` can run for minutes and freeze the turn (the
  # operator then interrupts, killing all in-flight work) - and it only rejects
  # the noise dirs AFTER paying to walk into them.
  #
  # Prefer ripgrep when it is on the node's PATH. `rg --files` lists matching
  # files fast, honours `.gitignore`/`.ignore`, skips `.git` by default, and,
  # with the explicit `!.git/`/`!_build/`/`!deps/`/`!node_modules/` globs, prunes
  # the noise dirs DURING the descent instead of enumerating a 260MB symlinked
  # `_build` on every call and discarding it afterwards. Borrowed from Codex
  # file-search, which drives its walk through the ripgrep `ignore` crate for
  # exactly these reasons; ripgrep is already a dependency of `file_grep`.
  # Availability is decided by the SAME detection `file_grep` uses
  # (`FileGrepBackend.executable/0`), so the two tools never disagree about
  # whether `rg` is present.
  #
  # When ripgrep is absent we fall back to the bounded, throwaway-process
  # `Path.wildcard/2` walk below, unchanged.
  defp bounded_wildcard(pattern, base) do
    case FileGrepBackend.executable() do
      nil -> wildcard_walk(pattern, base)
      exe -> ripgrep_files(exe, pattern, base)
    end
  end

  # `--hidden` mirrors `Path.wildcard(match_dot: true)`: without it `rg` skips
  # every dotfile, so `.github/`, `.env.example` and `.gitignore` would go
  # missing. But `--hidden` also un-skips `.git/`, so the noise-dir globs must
  # exclude it explicitly, exactly as `file_grep`'s unrestricted pass does. The
  # exclusions cover the full `Constants.noise_dirs/0` set - a single source of
  # truth shared with the post-walk `in_noise_dir?/1` reject - and are dropped
  # when the caller NAMES a noise dir in the pattern, so `.git/**` still works
  # (matching `filter_git?` in `glob_in/2`).
  defp ripgrep_files(exe, pattern, base) do
    # `rg --glob` matches against each path RELATIVE TO THE CURRENT WORKING
    # DIRECTORY (or absolute, for absolute paths), not relative to the search
    # root — so a base-relative pattern like `.git/*` never matches
    # `/somewhere/else/.git/HEAD` when the process cwd is elsewhere. Pass the
    # pattern twice: as given, and anchored under `**/`, which is the
    # base-relative reading the caller (and `Path.wildcard/2`, the fallback
    # walk) means. Deduplicated so a pattern already written anchored does not
    # double-match.
    globs = Enum.uniq([pattern, "**/" <> pattern])

    args =
      ["--files", "--hidden"] ++
        Enum.flat_map(globs, &["--glob", &1]) ++
        noise_exclusion_globs(pattern) ++ [base]

    case BoundedCmd.run(exe, args,
           label: "file_glob (rg --files)",
           target: base,
           stderr_to_stdout: false,
           timeout_ms: Constants.walk_timeout_ms()
         ) do
      {:ok, output, 0} ->
        {:ok, String.split(output, "\n", trim: true)}

      # `rg --files` exits 1 when it listed nothing - a real, empty answer, not
      # a fault. Return `[]` so `glob_in/2` renders the "No files matched"
      # message, identical to an empty `Path.wildcard/2`.
      {:ok, _output, 1} ->
        {:ok, []}

      # 2+ (or 127 for a binary that vanished between detection and spawn) means
      # rg ran and errored. Fall back to the in-BEAM walk rather than report an
      # engine fault as "no matches".
      {:ok, _output, _} ->
        wildcard_walk(pattern, base)

      {:timeout, _} ->
        :timeout
    end
  end

  # Prune the noise dirs DURING the rg descent, not after. Skipped entirely when
  # the caller's pattern references a noise dir, so an explicit `.git/**` or
  # `_build/**` is still honoured - the same gate `glob_in/2` applies to the
  # post-walk reject via `filter_git?`. Trailing `/` restricts each exclusion to
  # directories, mirroring `file_grep`'s `!.git/`.
  defp noise_exclusion_globs(pattern) do
    if references_noise_dir?(pattern) do
      []
    else
      Enum.flat_map(Constants.noise_dirs(), fn dir -> ["--glob", "!" <> dir <> "/"] end)
    end
  end

  # Fallback used only when ripgrep is not on the PATH. `Path.wildcard/2` walks
  # the whole tree and follows symlinks, so it runs under a hard deadline in a
  # throwaway process: past the deadline the walk is brutally killed and we
  # return actionable guidance instead of hanging.
  defp wildcard_walk(pattern, base) do
    task =
      Task.async(fn ->
        base
        |> Path.join(pattern)
        # `match_dot: true` is the whole reason dotfiles are visible at all.
        # Without it `Path.wildcard/2` refuses to match any component beginning
        # with `.`, so `**/*` skipped `.github/`, `.env.example`, `.gitignore`
        # and every dot-directory beneath them — not "returned them ranked low",
        # but never returned them under any pattern the caller could write.
        |> Path.wildcard(match_dot: true)
      end)

    case Task.yield(task, Constants.walk_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, matched} -> {:ok, matched}
      _ -> :timeout
    end
  end

  defp walk_timed_out_message(base) do
    secs = div(Constants.walk_timeout_ms(), 1000)

    "Search under #{base} was stopped after #{secs}s to avoid freezing the turn. " <>
      "This path holds a large or symlinked tree (usually _build, deps, .git or " <>
      "node_modules). Narrow the search: set `path` to a specific subdirectory " <>
      "(e.g. lib/ or test/), or make the pattern more specific."
  end

  defp format_glob_result(all, pattern, base, filter_git?, max) do
    total = length(all)
    shown = Enum.take(all, max)

    case shown do
      [] ->
        {:ok, Messages.no_matches(pattern, base, entry_count(base), filter_git?)}

      files ->
        header =
          if total > max do
            Messages.truncated(length(files), total, base)
          else
            "#{total} #{if total == 1, do: "file", else: "files"} found"
          end

        body = files |> Enum.map(&decorate/1) |> Enum.join("\n")

        # Same reasoning as `file_grep`'s spread trailer: a multi-file match IS
        # a list of independent next reads, and saying so at the END of the
        # result keeps the signal adjacent to the decision instead of thousands
        # of tokens behind it.
        trailer =
          if length(files) > 1 do
            "\n\n(#{length(files)} paths. Reading several of them is independent work — " <>
              "issue those file_read calls together in one turn, not one per turn.)"
          else
            ""
          end

        {:ok, "#{header}:\n#{body}#{trailer}"}
    end
  end

  # A glob can match directories as well as files, and a caller that pipes a
  # directory into `file_read` gets an avoidable error. Marking them costs one
  # character and mirrors how `FileRead.PathResolve` decorates its suggestions,
  # so the two tools describe the filesystem the same way.
  defp decorate(path) do
    if File.dir?(path), do: path <> "/", else: path
  end

  defp entry_count(base) do
    case File.ls(base) do
      {:ok, entries} -> length(entries)
      _ -> 0
    end
  end

  defp sensitive?(path) do
    Enum.any?(Constants.sensitive_paths(), &String.contains?(path, &1))
  end

  defp in_noise_dir?(path) do
    Enum.any?(Constants.noise_dirs(), fn dir ->
      String.contains?(path, "/" <> dir <> "/") or String.ends_with?(path, "/" <> dir)
    end)
  end

  defp references_noise_dir?(pattern) do
    Enum.any?(Constants.noise_dirs(), &String.contains?(pattern, &1))
  end

  # Canonicalise before comparing: the roots are canonical, so an unresolved
  # path is compared in the wrong namespace and /tmp is denied on macOS.
  defp allowed?(expanded_path) do
    OptimalSystemAgent.Agent.Safety.PathPolicy.within_read_roots?(expanded_path)
  end
end
