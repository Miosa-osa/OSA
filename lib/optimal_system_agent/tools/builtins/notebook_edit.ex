defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit do
  @behaviour MiosaTools.Behaviour

  @moduledoc """
  Read and edit Jupyter notebooks (.ipynb files).

  Supports reading cells, adding new cells, editing existing cells,
  deleting cells, and moving cells within the notebook.
  """

  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [
    ".ssh/id_rsa",
    ".ssh/id_ed25519",
    ".ssh/id_ecdsa",
    ".ssh/id_dsa",
    ".gnupg/",
    ".aws/credentials",
    ".env",
    "/etc/shadow",
    "/etc/sudoers",
    "/etc/master.passwd",
    ".netrc",
    ".npmrc",
    ".pypirc"
  ]
  @blocked_write_paths [
    ".ssh/",
    ".gnupg/",
    "/etc/",
    "/boot/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/var/",
    ".aws/",
    ".env"
  ]

  @impl true
  def name, do: "notebook_edit"

  @impl true
  def description,
    do:
      "Read and edit Jupyter notebooks (.ipynb files). Can read cells, add new cells, edit existing cells, delete cells, and move cells."

  @impl true
  def safety, do: :write_safe

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["read", "add_cell", "edit_cell", "delete_cell", "move_cell"],
          "description" => "Action to perform on the notebook"
        },
        "path" => %{
          "type" => "string",
          "description" => "Absolute path to the .ipynb file"
        },
        "index" => %{
          "type" => "integer",
          "description" => "Cell index (for edit_cell, delete_cell, move_cell)"
        },
        "cell_type" => %{
          "type" => "string",
          "enum" => ["code", "markdown"],
          "description" => "Cell type (for add_cell, edit_cell; default: code)"
        },
        "source" => %{
          "type" => "string",
          "description" => "Cell content (for add_cell, edit_cell)"
        },
        "position" => %{
          "type" => "integer",
          "description" => "Target position (for move_cell, add_cell; add_cell defaults to end)"
        }
      },
      "required" => ["action", "path"]
    }
  end

  @impl true
  def execute(%{"action" => action, "path" => path} = params)
      when is_binary(path) and is_binary(action) do
    expanded = Path.expand(path)

    cond do
      not String.ends_with?(expanded, ".ipynb") ->
        {:error, "Path must be a .ipynb file: #{path}"}

      action in ["edit_cell", "add_cell", "delete_cell", "move_cell"] and
          not write_allowed?(expanded) ->
        {:error, "Access denied: #{path} targets a protected location"}

      action == "read" and not read_allowed?(expanded) ->
        {:error, "Access denied: #{path} is outside allowed paths or is a sensitive file"}

      true ->
        dispatch(action, expanded, path, params)
    end
  end

  def execute(%{"action" => _, "path" => _}), do: {:error, "action and path must be strings"}
  def execute(_), do: {:error, "Missing required parameters: action, path"}

  # ── Action dispatch ──────────────────────────────────────────────

  defp dispatch("read", expanded, display, _params) do
    with {:ok, nb} <- read_notebook(expanded, display) do
      cells = Map.get(nb, "cells", [])

      if cells == [] do
        {:ok, "Empty notebook (0 cells)"}
      else
        output =
          cells
          |> Enum.with_index()
          |> Enum.map_join("\n\n", fn {cell, idx} -> format_cell(cell, idx) end)

        {:ok, output}
      end
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
        cells
        |> List.update_at(index, fn cell ->
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
     "Unknown action: #{action}. Use read, add_cell, edit_cell, delete_cell, or move_cell."}
  end

  # ── Notebook I/O ─────────────────────────────────────────────────

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

  # ── Cell helpers ─────────────────────────────────────────────────

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

  # ── Param validation ─────────────────────────────────────────────

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

  # ── Security (matches FileEdit pattern) ──────────────────────────

  defp read_allowed?(expanded_path) do
    sensitive = Enum.any?(@sensitive_paths, fn p -> String.contains?(expanded_path, p) end)

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
      blocked = Enum.any?(@blocked_write_paths, fn p -> String.contains?(expanded_path, p) end)

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
    Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp allowed_write_paths do
    Application.get_env(:optimal_system_agent, :allowed_write_paths, @default_allowed_paths)
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
