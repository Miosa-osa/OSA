defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `notebook_edit`.

  Three-stage pipeline:
    * `validate/2`           — type checks input shape and validates action enum (cheap)
    * `check_permissions/2`  — path allowlist + blocked write-path deny
    * `execute/2`            — actual notebook read or mutation

  ## Return shapes
  On success, `execute/2` returns:
    * `{:ok, result_string}` for all mutating actions.
    * `{:ok, result_string, %{cell_count: n, path: expanded}}` for `read`, so
      the TUI render layer has structured cell-count metadata without re-parsing.

  Notebook JSON is written with `pretty: true` via Jason to preserve
  human-readable formatting and field order. Unknown top-level fields in the
  notebook map are passed through untouched (Jason merges the decoded map).
  """

  alias OptimalSystemAgent.Tools.Builtins.NotebookEdit.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action, "path" => path} = input, _ctx)
      when is_binary(action) and is_binary(path) do
    if action in Constants.actions() do
      {:ok, input}
    else
      {:error,
       "Unknown action: #{action}. Use #{Enum.join(Constants.actions(), ", ")}.", -32_602}
    end
  end

  def validate(%{"action" => _, "path" => _}, _ctx),
    do: {:error, "action and path must both be strings", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: action, path", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"action" => action, "path" => path} = input, _ctx) do
    expanded = Path.expand(path)

    cond do
      not String.ends_with?(expanded, ".ipynb") ->
        {:deny, "Path must be a .ipynb file: #{path}"}

      action == "read" and sensitive?(expanded) ->
        {:deny, "Access denied: #{path} is a sensitive system file"}

      action == "read" and not read_allowed?(expanded) ->
        {:deny, "Access denied: #{path} is outside allowed read paths"}

      action in ~w(add_cell edit_cell delete_cell move_cell) and
          not write_allowed?(expanded) ->
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
  def execute(%{"action" => action, "path" => path} = params, _ctx) do
    expanded = Path.expand(path)
    dispatch(action, expanded, path, params)
  end

  def execute(_, _ctx),
    do: {:error, "Missing required parameters: action, path"}

  # ── Action dispatch ───────────────────────────────────────────────────

  defp dispatch("read", expanded, display, _params) do
    with {:ok, nb} <- read_notebook(expanded, display) do
      cells = Map.get(nb, "cells", [])

      result =
        if cells == [] do
          "Empty notebook (0 cells)"
        else
          cells
          |> Enum.with_index()
          |> Enum.map_join("\n\n", fn {cell, idx} -> format_cell(cell, idx) end)
        end

      {:ok, result, %{cell_count: length(cells), path: expanded}}
    end
  end

  defp dispatch("add_cell", expanded, display, params) do
    source = params["source"] || ""
    cell_type = params["cell_type"] || "code"

    with {:ok, nb} <- read_notebook(expanded, display) do
      cells = Map.get(nb, "cells", [])
      new_cell = build_cell(cell_type, source)
      position = params["position"]

      new_cells =
        if is_nil(position) or position >= length(cells) do
          cells ++ [new_cell]
        else
          pos = max(position, 0)
          List.insert_at(cells, pos, new_cell)
        end

      write_notebook(
        expanded,
        display,
        Map.put(nb, "cells", new_cells),
        "Added #{cell_type} cell at index #{position || length(cells)}"
      )
    end
  end

  defp dispatch("edit_cell", expanded, display, params) do
    with {:ok, index} <- require_index(params),
         {:ok, nb} <- read_notebook(expanded, display),
         {:ok, _cell} <- get_cell(nb, index) do
      cells = Map.get(nb, "cells", [])
      source = params["source"] || ""
      cell_type = params["cell_type"]

      updated =
        List.update_at(cells, index, fn cell ->
          cell
          |> Map.put("source", split_source(source))
          |> then(fn c ->
            if cell_type, do: Map.put(c, "cell_type", cell_type), else: c
          end)
        end)

      write_notebook(expanded, display, Map.put(nb, "cells", updated), "Edited cell [#{index}]")
    end
  end

  defp dispatch("delete_cell", expanded, display, params) do
    with {:ok, index} <- require_index(params),
         {:ok, nb} <- read_notebook(expanded, display),
         {:ok, _cell} <- get_cell(nb, index) do
      cells = Map.get(nb, "cells", [])
      new_cells = List.delete_at(cells, index)

      write_notebook(
        expanded,
        display,
        Map.put(nb, "cells", new_cells),
        "Deleted cell [#{index}] (#{length(new_cells)} cells remaining)"
      )
    end
  end

  defp dispatch("move_cell", expanded, display, params) do
    with {:ok, index} <- require_index(params),
         {:ok, position} <- require_position(params),
         {:ok, nb} <- read_notebook(expanded, display),
         {:ok, _cell} <- get_cell(nb, index) do
      cells = Map.get(nb, "cells", [])
      {cell, rest} = List.pop_at(cells, index)
      target = min(max(position, 0), length(rest))
      new_cells = List.insert_at(rest, target, cell)

      write_notebook(
        expanded,
        display,
        Map.put(nb, "cells", new_cells),
        "Moved cell from [#{index}] to [#{target}]"
      )
    end
  end

  defp dispatch(action, _expanded, _display, _params) do
    {:error,
     "Unknown action: #{action}. Use #{Enum.join(Constants.actions(), ", ")}."}
  end

  # ── Notebook I/O ──────────────────────────────────────────────────────

  defp read_notebook(expanded, display) do
    case File.read(expanded) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, nb} when is_map(nb) -> {:ok, nb}
          {:ok, _} -> {:error, "Invalid notebook structure in #{display}"}
          {:error, _} -> {:error, "Failed to parse JSON in #{display}"}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{display}"}

      {:error, reason} ->
        {:error, "Cannot read #{display}: #{reason}"}
    end
  end

  defp write_notebook(expanded, display, notebook, message) do
    case Jason.encode(notebook, pretty: true) do
      {:ok, json} ->
        case File.write(expanded, json) do
          :ok -> {:ok, "#{message} in #{display}"}
          {:error, reason} -> {:error, "Failed to write #{display}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to encode notebook: #{inspect(reason)}"}
    end
  end

  # ── Cell helpers ──────────────────────────────────────────────────────

  defp build_cell(cell_type, source) do
    base = %{
      "cell_type" => cell_type,
      "source" => split_source(source),
      "metadata" => %{}
    }

    if cell_type == "code" do
      Map.merge(base, %{"execution_count" => nil, "outputs" => []})
    else
      base
    end
  end

  defp split_source(""), do: []

  defp split_source(source) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      if idx < length(lines) - 1, do: line <> "\n", else: line
    end)
  end

  defp format_cell(cell, index) do
    type = Map.get(cell, "cell_type", "unknown")
    source = cell |> Map.get("source", []) |> join_source() |> String.trim_trailing()
    indented = source |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

    output_summary =
      case Map.get(cell, "outputs", []) do
        [] -> ""
        outputs -> "\n  --- Output: #{summarize_outputs(outputs)} ---"
      end

    "[#{index}] #{type}:\n#{indented}#{output_summary}"
  end

  defp join_source(source) when is_list(source), do: Enum.join(source)
  defp join_source(source) when is_binary(source), do: source
  defp join_source(_), do: ""

  defp summarize_outputs(outputs) do
    outputs
    |> Enum.map(fn output ->
      cond do
        is_map(output) and Map.has_key?(output, "text") ->
          text = output["text"]
          text = if is_list(text), do: Enum.join(text), else: to_string(text)
          String.slice(text, 0, 80) |> String.trim()

        is_map(output) and Map.has_key?(output, "data") ->
          keys = Map.keys(output["data"]) |> Enum.join(", ")
          "data(#{keys})"

        is_map(output) and output["output_type"] == "error" ->
          ename = Map.get(output, "ename", "Error")
          "#{ename}: #{Map.get(output, "evalue", "")}" |> String.slice(0, 80)

        true ->
          "output"
      end
    end)
    |> Enum.join("; ")
  end

  # ── Param validation helpers ──────────────────────────────────────────

  defp require_index(%{"index" => index}) when is_integer(index), do: {:ok, index}

  defp require_index(%{"index" => index}) when is_binary(index) do
    case Integer.parse(index) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "index must be an integer"}
    end
  end

  defp require_index(_), do: {:error, "Missing required parameter: index"}

  defp require_position(%{"position" => pos}) when is_integer(pos), do: {:ok, pos}

  defp require_position(%{"position" => pos}) when is_binary(pos) do
    case Integer.parse(pos) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "position must be an integer"}
    end
  end

  defp require_position(_), do: {:error, "Missing required parameter: position"}

  defp get_cell(notebook, index) do
    cells = Map.get(notebook, "cells", [])

    if index >= 0 and index < length(cells) do
      {:ok, Enum.at(cells, index)}
    else
      {:error, "Cell index #{index} out of range (notebook has #{length(cells)} cells)"}
    end
  end

  # ── Security ──────────────────────────────────────────────────────────

  defp sensitive?(expanded_path) do
    Enum.any?(Constants.sensitive_paths(), fn p -> String.contains?(expanded_path, p) end)
  end

  defp read_allowed?(expanded_path) do
    if sensitive?(expanded_path) do
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
