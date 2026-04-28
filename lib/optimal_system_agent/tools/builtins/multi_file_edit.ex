defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "multi_file_edit"

  @impl true
  def description,
    do: "Apply edits across multiple files atomically. All edits succeed or none are applied."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "edits" => %{
          "type" => "array",
          "description" =>
            "List of edits to apply. Each edit requires path, old_string, and new_string.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Path to the file. Relative paths resolve to ~/.osa/workspace/."
              },
              "old_string" => %{
                "type" => "string",
                "description" => "Exact text to find and replace (first occurrence only)"
              },
              "new_string" => %{
                "type" => "string",
                "description" => "Replacement text"
              }
            },
            "required" => ["path", "old_string", "new_string"]
          }
        }
      },
      "required" => ["edits"]
    }
  end

  @impl true
  def execute(%{"edits" => edits}) when is_list(edits) and length(edits) > 0 do
    # Resolve and validate every edit before touching any file
    resolved = Enum.map(edits, &resolve_edit/1)

    # Read each file and validate old_string is present
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
      # All valid — apply all edits
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
        summary =
          Enum.map_join(apply_results, "\n", fn {:ok, display_path, lines_changed} ->
            "  #{display_path} (#{lines_changed} lines changed)"
          end)

        count = length(apply_results)

        {:ok, "Edited #{count} #{if count == 1, do: "file", else: "files"}:\n#{summary}"}
      end
    end
  end

  def execute(%{"edits" => []}), do: {:error, "edits list is empty"}
  def execute(%{"edits" => _}), do: {:error, "edits must be a list of edit objects"}
  def execute(_), do: {:error, "Missing required parameter: edits"}

  # --- Helpers ---

  defp resolve_edit(%{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded =
      if relative_path?(path) do
        Path.expand(Path.join("~/.osa/workspace", path))
      else
        Path.expand(path)
      end

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

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end
end
