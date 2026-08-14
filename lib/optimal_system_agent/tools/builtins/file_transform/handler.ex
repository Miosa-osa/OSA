defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.Handler do
  @moduledoc """
  Validation, permission and execution logic for `file_transform`.

  ## The authorisation property, stated exactly

  There is exactly one path in a `file_transform` call, and it is the only path
  the tool touches. Concretely, the whole filesystem surface of `execute/2` is:

      File.read(declared)                     # the declared path
      File.write(tmp)                         # a sibling of the declared path
      File.rename(tmp, declared)               # onto the declared path
      File.rm(tmp)                             # cleanup on any failure

  `tmp` is built here from `declared` — `Path.dirname(declared)` plus a random
  basename — so it is not a value the model can influence. Every one of those
  four is reached only after `PathPolicy.check_write/2` has approved `declared`,
  and `check_write/2` is re-run inside `execute/2` (defence in depth, exactly as
  `FileWrite.Handler` does) so the property holds even when `execute/2` is
  invoked directly.

  No subprocess is spawned. No model-supplied string is evaluated, compiled as
  code, or interpreted as a path. `Ops` selects a fixed Elixir function by atom
  and applies it to a binary. So "the script declared /app/foo.py and wrote
  /etc/passwd" is not a case that has to be *detected*: there is no operation in
  the vocabulary that can name a second file. See
  `docs/design/context-free-edits.md` §2 for the alternatives that were
  considered and rejected.

  ## Atomicity

  All operations are applied in memory. If any one of them fails its
  expectation, `execute/2` returns an error and **the file is never opened for
  writing**. Only a fully successful op list reaches the temp-file-then-rename
  swap, and `File.rename/2` within a directory is atomic on every filesystem we
  support, so no reader can observe a half-written file.

  ## Result shape

  The result is O(number of operations), not O(filesize) and not O(edit size):

      /app/eval.scm — 3 operations applied
        1. replace_regex — 1 replaced
        2. delete_matching_lines — 2 lines deleted
        3. assert_balanced — balance: 0 (() balanced)
      812 -> 809 lines, 24113 -> 24066 bytes

  The replacement text is NOT echoed. `file_edit` returns a synthetic diff
  containing both `old_string` and `new_string`, so every byte of an edit is
  paid for twice; that is measured at ~29 KB of pure duplication on one
  benchmark task. The confirmation the model actually needs — *did this break
  anything* — arrives instead from the post-edit validation hook, which is the
  same hook `file_edit` and `file_write` already run.
  """

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEditHandler
  alias OptimalSystemAgent.Tools.Builtins.FileTransform.Ops
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  # Transforms hold the whole file in memory twice (before and after). A cap
  # keeps a `file_transform` on a multi-gigabyte log from taking the node down.
  @max_bytes 5_000_000

  # A catastrophically-backtracking regex is the one denial-of-service the model
  # can still author, since `Regex` runs in the calling process and cannot be
  # interrupted from outside. Applying the op list inside a task bounds it.
  @apply_timeout_ms 10_000

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path, "operations" => ops} = input, _ctx)
      when is_binary(path) and is_list(ops) do
    case Ops.validate(ops) do
      :ok -> {:ok, input}
      {:error, msg} -> {:error, msg, -32_602}
    end
  end

  def validate(%{"path" => _, "operations" => _}, _ctx),
    do: {:error, "path must be a string and operations must be a list", -32_602}

  def validate(%{"path" => _}, _ctx),
    do: {:error, "Missing required parameter: operations", -32_602}

  def validate(%{"operations" => _}, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: path, operations", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"path" => path} = input, _ctx) do
    case PathPolicy.check_write(normalize(path), path) do
      :ok -> {:allow, input}
      {:deny, _} = denial -> denial
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:ok, String.t(), map()} | {:error, String.t()}
  def execute(%{"path" => path, "operations" => ops} = input, ctx) when is_list(ops) do
    expanded = Path.expand(normalize(path))

    # Defence in depth: the same decision check_permissions/2 made, re-made here
    # so the boundary holds for direct callers. Fails closed.
    case PathPolicy.check_write(expanded, path) do
      {:deny, msg} -> {:error, msg}
      :ok -> run(expanded, path, ops, truthy(Map.get(input, "dry_run")), session_id(ctx))
    end
  end

  def execute(_, _ctx), do: {:error, "Missing required parameters: path, operations"}

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp run(expanded, display, ops, dry_run?, session) do
    with {:ok, content} <- read_source(expanded, display),
         {:ok, out, reports} <- apply_bounded(content, ops, expanded) do
      if dry_run? do
        {:ok, dry_run_report(display, content, out, reports)}
      else
        commit(expanded, display, content, out, reports, session)
      end
    end
  end

  # ── Reading the source ────────────────────────────────────────────────

  defp read_source(expanded, display) do
    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory}} ->
        {:error,
         "Cannot transform #{display}: it is a directory, not a file. " <>
           "Name a file inside it."}

      {:ok, %File.Stat{size: size}} when size > @max_bytes ->
        {:error,
         "Cannot transform #{display}: it is #{size} bytes, over the #{@max_bytes}-byte " <>
           "transform limit. Use `shell_execute` with a streaming tool for a file this size."}

      {:ok, _} ->
        case File.read(expanded) do
          {:ok, content} ->
            {:ok, content}

          {:error, reason} ->
            {:error,
             "Cannot read #{display}: #{:file.format_error(reason)} (#{inspect(reason)}). " <>
               "The file was not modified."}
        end

      {:error, :enoent} ->
        {:error,
         "Cannot transform #{display}: no such file. `file_transform` only modifies files " <>
           "that already exist — use `file_write` to create one."}

      {:error, reason} ->
        {:error,
         "Cannot stat #{display}: #{:file.format_error(reason)} (#{inspect(reason)}). " <>
           "The file was not modified."}
    end
  end

  # ── Applying, under a time bound ──────────────────────────────────────

  defp apply_bounded(content, ops, path) do
    task = Task.async(fn -> Ops.apply_all(content, ops, path: path) end)

    case Task.yield(task, @apply_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error,
         "The transform did not finish within #{div(@apply_timeout_ms, 1000)}s and was " <>
           "abandoned. Nothing was written. This is almost always a regex that backtracks " <>
           "catastrophically (nested quantifiers such as `(a+)+`). Anchor the pattern or " <>
           "match line-by-line with `delete_matching_lines`."}

      {:exit, reason} ->
        {:error, "The transform crashed (#{inspect(reason)}). Nothing was written."}
    end
  end

  # ── Committing ────────────────────────────────────────────────────────

  defp commit(expanded, display, before, after_content, reports, session) do
    cond do
      before == after_content ->
        # Every operation met its expectation and the bytes did not move. That
        # is a probe-only transform (`count` / `assert_balanced`) or an edit
        # that was already applied. Neither is a failure, and neither should
        # cost a write.
        {:ok,
         "#{display} — #{length(reports)} operation(s), no change to the file\n" <>
           Enum.join(reports, "\n")}

      true ->
        case atomic_write(expanded, after_content) do
          :ok ->
            FileState.record_write(session, expanded)

            note =
              FileEditHandler.file_changed_note(%{
                path: expanded,
                tool: "file_transform",
                operation: :edit
              })

            summary = summary(display, before, after_content, reports)

            {:ok, summary <> note,
             %{path: expanded, operations: length(reports), bytes: byte_size(after_content)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Write to a sibling temp file, then rename over the target. The temp name is
  # derived from `target` here — it is never a model-supplied value — so the
  # write surface is still exactly one directory: the declared file's own. It is
  # deliberately NOT a dotfile: a dotfile sibling of a target directly under
  # `$HOME` would be refused by `dotfile_outside_osa?/1`, and a staging path the
  # policy would refuse is a staging path in the wrong place. Because it is not,
  # the same `check_write/2` that approved the target approves it, and we assert
  # that rather than assuming it.
  defp atomic_write(target, content) do
    dir = Path.dirname(target)
    tmp = Path.join(dir, Path.basename(target) <> ".osa-transform-" <> token())

    with :ok <- staging_allowed(tmp),
         :ok <- File.write(tmp, content),
         :ok <- preserve_mode(target, tmp),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, reason} when is_binary(reason) ->
        File.rm(tmp)
        {:error, reason}

      {:error, reason} ->
        File.rm(tmp)

        {:error,
         "Could not replace #{target}: #{:file.format_error(reason)} (#{inspect(reason)}). " <>
           "The original file is untouched — the new content was staged in a temporary " <>
           "file and that file has been removed."}
    end
  end

  # A rename replaces the inode, so the target's permission bits would otherwise
  # be silently reset to the umask default. An executable script that stops
  # being executable after an edit is a corruption of exactly the kind this tool
  # promises not to cause.
  defp preserve_mode(target, tmp) do
    case File.stat(target) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(tmp, rem(mode, 0o10000))
      _ -> :ok
    end
  end

  defp staging_allowed(tmp) do
    case PathPolicy.check_write(tmp, tmp) do
      :ok ->
        :ok

      {:deny, reason} ->
        {:error, "Refusing to stage the new content next to the target: #{reason}"}
    end
  end

  defp token, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # ── Reporting ─────────────────────────────────────────────────────────

  defp summary(display, before, after_content, reports) do
    "#{display} — #{length(reports)} operation(s) applied\n" <>
      Enum.join(reports, "\n") <>
      "\n" <> delta(before, after_content)
  end

  defp dry_run_report(display, before, after_content, reports) do
    verdict =
      if before == after_content,
        do: "no change to the file",
        else: "would change the file: " <> delta(before, after_content)

    "DRY RUN — nothing was written.\n#{display} — #{length(reports)} operation(s)\n" <>
      Enum.join(reports, "\n") <> "\n" <> verdict
  end

  defp delta(before, after_content) do
    "#{line_count(before)} -> #{line_count(after_content)} lines, " <>
      "#{byte_size(before)} -> #{byte_size(after_content)} bytes"
  end

  defp line_count(""), do: 0
  defp line_count(content), do: content |> String.split("\n") |> length()

  # ── Private ───────────────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  # Same relative-path convention as file_write/file_edit: a bare relative path
  # roots at the OSA workspace rather than at whatever cwd the node happens to
  # have.
  defp normalize(path) do
    if relative?(path), do: Path.join("~/.osa/workspace", path), else: path
  end

  defp relative?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end
end
