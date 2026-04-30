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
      apply_results = Enum.map(validation_results, &apply_edit/1)

      failures =
        Enum.filter(apply_results, fn
          {:error, _, _} -> true
          _ -> false
        end)

      if failures != [] do
        error_lines =
          Enum.map_join(failures, "\n", fn {:error, display_path, reason} ->
            "  - #{display_path}: #{reason}"
          end)

        {:error, "Apply failed (some files may have been modified):\n#{error_lines}"}
      else
        per_file =
          Enum.map(apply_results, fn {:ok, display_path, lines_changed} ->
            %{path: display_path, lines_changed: lines_changed}
          end)

        summary =
          Enum.map_join(per_file, "\n", fn %{path: dp, lines_changed: lc} ->
            "  #{dp} (#{lc} lines changed)"
          end)

        count = length(per_file)

        result =
          "Edited #{count} #{if count == 1, do: "file", else: "files"}:\n#{summary}"

        {:ok, result, %{results: per_file, count: count}}
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
            if String.contains?(content, old) do
              {:valid, dp, ep, old, new, content}
            else
              {:error, dp, "old_string not found in file"}
            end

          {:error, reason} ->
            {:error, dp, "cannot read file: #{reason}"}
        end
    end
  end

  defp apply_edit({:valid, display_path, expanded_path, old, new, content}) do
    new_content = String.replace(content, old, new, global: false)

    case File.write(expanded_path, new_content) do
      :ok ->
        old_line_count = old |> String.split("\n") |> length()
        {:ok, display_path, old_line_count}

      {:error, reason} ->
        {:error, display_path, "write failed: #{reason}"}
    end
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
