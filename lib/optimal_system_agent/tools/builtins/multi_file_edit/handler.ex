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

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Constants
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
    denied =
      Enum.find_value(edits, fn
        %{"path" => path} when is_binary(path) ->
          expanded = resolve_path(path)

          cond do
            not write_allowed?(expanded) ->
              "Access denied: #{path} targets a protected location"

            true ->
              nil
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
  def execute(%{"edits" => edits}, _ctx) when is_list(edits) do
    resolved = Enum.map(edits, &resolve_edit/1)
    validation_results = Enum.map(resolved, &validate_edit/1)

    errors =
      Enum.filter(validation_results, fn
        {:error, _, _} -> true
        _ -> false
      end)

    if errors != [] do
      error_lines =
        Enum.map_join(errors, "\n", fn {:error, display_path, reason} ->
          "  - #{display_path}: #{reason}"
        end)

      {:error, "Validation failed — no files were modified:\n#{error_lines}"}
    else
      # All edits validated. Apply them ATOMICALLY (all-or-nothing) so a write
      # that fails partway can never leave the repo half-edited (BUG B).
      case apply_atomic(validation_results) do
        {:ok, per_file} ->
          summary =
            Enum.map_join(per_file, "\n", fn %{path: dp, lines_changed: lc} ->
              "  #{dp} (#{lc} lines changed)"
            end)

          count = length(per_file)

          result =
            "Edited #{count} #{if count == 1, do: "file", else: "files"}:\n#{summary}"

          {:ok, result, %{results: per_file, count: count}}

        {:error, reason} ->
          {:error, "Apply failed — all changes rolled back, no files were modified:\n  #{reason}"}
      end
    end
  end

  def execute(_, _ctx), do: {:error, "Missing required parameter: edits"}

  # ── Private ───────────────────────────────────────────────────────────

  defp resolve_edit(%{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded = resolve_path(path)
    %{display_path: path, expanded_path: expanded, old_string: old, new_string: new}
  end

  defp resolve_edit(edit), do: {:invalid, inspect(edit)}

  defp validate_edit({:invalid, raw}) do
    {:error, raw, "malformed edit (missing path, old_string, or new_string)"}
  end

  defp validate_edit(%{display_path: dp, expanded_path: ep, old_string: old, new_string: new}) do
    cond do
      old == "" ->
        {:error, dp, "old_string cannot be empty"}

      old == new ->
        {:error, dp, "old_string and new_string are identical"}

      not File.exists?(ep) ->
        {:error, dp, "file not found"}

      true ->
        case File.read(ep) do
          {:ok, content} ->
            cond do
              not String.contains?(content, old) ->
                {:error, dp, "old_string not found in file"}

              # Ambiguity guard mirroring single-file file_edit: apply_atomic uses
              # global: false and would silently rewrite only the FIRST match,
              # committing a wrong edit. Require a unique match.
              occurrence_count(content, old) > 1 ->
                {:error, dp,
                 "old_string found multiple times — must be unique; add surrounding context"}

              true ->
                {:valid, dp, ep, old, new, content}
            end

          {:error, reason} ->
            {:error, dp, "cannot read file: #{reason}"}
        end
    end
  end

  defp occurrence_count(content, old) do
    (content |> String.split(old) |> length()) - 1
  end

  # Apply every validated edit atomically: all files change or none do.
  #
  # Two-phase commit over the filesystem:
  #   1. STAGE  — compute each file's new content and write it to a sibling
  #               temp file (same directory, so the final rename is atomic and
  #               never crosses filesystems). Any staging failure aborts here,
  #               deleting every temp already written — zero target files touched.
  #   2. COMMIT — rename each temp over its target. If a rename fails partway,
  #               restore the targets already renamed from their in-memory
  #               originals and delete the remaining temps, so the on-disk state
  #               is exactly what it was before the call.
  defp apply_atomic(validation_results) do
    edits =
      Enum.map(validation_results, fn
        {:valid, display_path, expanded_path, old, new, content} ->
          %{
            display_path: display_path,
            expanded_path: expanded_path,
            content: content,
            new_content: String.replace(content, old, new, global: false),
            lines_changed: old |> String.split("\n") |> length()
          }
      end)

    case stage_all(edits) do
      {:ok, staged} -> commit_all(staged)
      {:error, reason} -> {:error, reason}
    end
  end

  # Phase 1 — write every new content to a temp file. Returns {:ok, staged}
  # where staged pairs each edit with its temp path, or {:error, reason} after
  # cleaning up any temps already created.
  defp stage_all(edits) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, staged} ->
      tmp = temp_path(edit.expanded_path)

      case File.write(tmp, edit.new_content) do
        :ok ->
          {:cont, {:ok, [Map.put(edit, :tmp_path, tmp) | staged]}}

        {:error, reason} ->
          Enum.each(staged, fn s -> File.rm(s.tmp_path) end)
          {:halt, {:error, "#{edit.display_path}: staging write failed: #{reason}"}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      {:error, _} = err -> err
    end
  end

  # Phase 2 — rename each temp over its target. On any failure, roll back every
  # target already committed (restoring the original in-memory content) and
  # remove the remaining temps.
  defp commit_all(staged) do
    Enum.reduce_while(staged, {:ok, []}, fn edit, {:ok, committed} ->
      case File.rename(edit.tmp_path, edit.expanded_path) do
        :ok ->
          result = %{path: edit.display_path, lines_changed: edit.lines_changed}
          {:cont, {:ok, [{edit, result} | committed]}}

        {:error, reason} ->
          rollback(committed)
          # Remaining (uncommitted) temps, including this one, are cleaned up.
          remaining = Enum.drop_while(staged, fn s -> s != edit end)
          Enum.each(remaining, fn s -> File.rm(s.tmp_path) end)
          {:halt, {:error, "#{edit.display_path}: rename failed: #{reason}"}}
      end
    end)
    |> case do
      {:ok, committed} -> {:ok, committed |> Enum.map(&elem(&1, 1)) |> Enum.reverse()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(committed) do
    Enum.each(committed, fn {edit, _result} ->
      File.write(edit.expanded_path, edit.content)
    end)
  end

  defp temp_path(expanded_path) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    expanded_path <> ".osa-tmp-" <> suffix
  end

  defp resolve_path(path) do
    normalized =
      if relative_path?(path) do
        Path.join("~/.osa/workspace", path)
      else
        path
      end

    Path.expand(normalized)
  end

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end

  defp write_allowed?(expanded_path) do
    blocked =
      Enum.any?(Constants.blocked_write_paths(), fn pattern ->
        String.contains?(expanded_path, pattern)
      end)

    if blocked do
      false
    else
      check_path =
        if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

      Enum.any?(allowed_write_paths(), fn allowed ->
        String.starts_with?(check_path, allowed)
      end)
    end
  end

  defp allowed_write_paths do
    configured =
      Application.get_env(
        :optimal_system_agent,
        :allowed_write_paths,
        Constants.default_allowed_paths()
      )

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end
end
