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

  ## On-disk format

  Notebook JSON is re-serialised to match what `nbformat` — Jupyter's own
  writer — produces: keys in sorted order, one-space indentation, and a
  trailing newline.

  This does NOT preserve the byte-for-byte layout of the file that was read,
  and the previous claim that it did was wrong twice over. `Jason.encode/2`
  serialises an Elixir map in `:maps.to_list/1` order, which is a function of
  the map's internal hashing, not of the source document — so every key in
  every cell was reordered arbitrarily on every edit — and `pretty: true`
  indents with two spaces where Jupyter uses one. A one-cell edit therefore
  rewrote every line of the notebook and produced a diff nobody could review.

  Matching `nbformat` instead makes the output deterministic and identical to
  what the user's own Jupyter would write on their next save, so an edit shows
  up in `git diff` as the cell that changed and nothing else. Unknown
  top-level and per-cell fields are still passed through untouched.
  """

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Tools.Builtins.NotebookEdit.Constants
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  @mutating_actions ~w(add_cell edit_cell delete_cell move_cell)

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

      action == "read" ->
        case PathPolicy.check_read(expanded, path) do
          :ok -> {:allow, input}
          {:deny, _} = denial -> denial
        end

      action in @mutating_actions ->
        # Same shared write decision as file_edit / file_write /
        # multi_file_edit. Notebook edits used to run their own copy, which
        # resolved no symlinks at all.
        case PathPolicy.check_write(expanded, path) do
          :ok -> {:allow, input}
          {:deny, _} = denial -> denial
        end

      true ->
        {:allow, input}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()}
          | {:ok, String.t(), map()}
          | {:error, String.t()}
  def execute(%{"action" => action, "path" => path} = params, ctx) do
    expanded = Path.expand(path)
    session = session_id(ctx)

    if action in @mutating_actions do
      # Two guarantees its three siblings had and `notebook_edit` did not:
      #
      #   * the write sandbox is re-checked here, so it holds even when
      #     `execute/2` is called directly, and
      #   * the notebook must have been read this session and be unchanged
      #     since — otherwise a cell index computed from a stale reading is
      #     applied to a file that has moved underneath it, deleting or
      #     overwriting the wrong cell.
      with :ok <- guard_write(expanded, path),
           :ok <- FileState.check_read(session, expanded) do
        dispatch(action, expanded, path, params, session)
      else
        {:deny, msg} -> {:error, msg}
        {:error, msg} -> {:error, msg}
      end
    else
      dispatch(action, expanded, path, params, session)
    end
  end

  def execute(_, _ctx),
    do: {:error, "Missing required parameters: action, path"}

  # ── Action dispatch ───────────────────────────────────────────────────

  defp session_id(%{session_id: s}), do: s
  defp session_id(_), do: nil

  defp guard_write(expanded, display) do
    case PathPolicy.check_write(expanded, display) do
      :ok -> :ok
      {:deny, _} = denial -> denial
    end
  end

  defp dispatch("read", expanded, display, _params, session) do
    with {:ok, nb} <- read_notebook(expanded, display) do
      # Reading a notebook satisfies the read-before-edit guard for the
      # subsequent mutating call, exactly as `file_read` does for `file_edit`.
      FileState.record_read(session, expanded)
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

  defp dispatch("add_cell", expanded, display, params, session) do
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
        "Added #{cell_type} cell at index #{position || length(cells)}",
        session
      )
    end
  end

  defp dispatch("edit_cell", expanded, display, params, session) do
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

      write_notebook(
        expanded,
        display,
        Map.put(nb, "cells", updated),
        "Edited cell [#{index}]",
        session
      )
    end
  end

  defp dispatch("delete_cell", expanded, display, params, session) do
    with {:ok, index} <- require_index(params),
         {:ok, nb} <- read_notebook(expanded, display),
         {:ok, _cell} <- get_cell(nb, index) do
      cells = Map.get(nb, "cells", [])
      new_cells = List.delete_at(cells, index)

      write_notebook(
        expanded,
        display,
        Map.put(nb, "cells", new_cells),
        "Deleted cell [#{index}] (#{length(new_cells)} cells remaining)",
        session
      )
    end
  end

  defp dispatch("move_cell", expanded, display, params, session) do
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
        "Moved cell from [#{index}] to [#{target}]",
        session
      )
    end
  end

  defp dispatch(action, _expanded, _display, _params, _session) do
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

  defp write_notebook(expanded, display, notebook, message, session) do
    case encode_notebook(notebook) do
      {:ok, json} ->
        case File.write(expanded, json) do
          :ok ->
            # Keep the read-state baseline in step with what we just wrote, so
            # a second edit in the same turn is not rejected as stale.
            FileState.record_write(session, expanded)
            {:ok, "#{message} in #{display}"}

          {:error, reason} ->
            {:error, "Failed to write #{display}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to encode notebook: #{inspect(reason)}"}
    end
  end

  @doc """
  Serialise a decoded notebook the way `nbformat` does: sorted keys, one-space
  indent, trailing newline. Exposed for tests.
  """
  @spec encode_notebook(map()) :: {:ok, String.t()} | {:error, term()}
  def encode_notebook(notebook) do
    case Jason.encode(canonical_order(notebook), pretty: [indent: " "]) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Jason serialises a map in whatever order `:maps.to_list/1` yields. Wrapping
  # each map in a `Jason.OrderedObject` with its keys sorted pins the order to
  # something deterministic and equal to nbformat's `sort_keys=True`.
  defp canonical_order(map) when is_map(map) and not is_struct(map) do
    values =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), canonical_order(v)} end)
      |> Enum.sort_by(&elem(&1, 0))

    %Jason.OrderedObject{values: values}
  end

  defp canonical_order(list) when is_list(list), do: Enum.map(list, &canonical_order/1)
  defp canonical_order(other), do: other

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
  #
  # All path decisions live in `Agent.Safety.PathPolicy`. This module used to
  # carry its own `sensitive?/1`, `read_allowed?/1`, `write_allowed?/1`,
  # allowlist expansion and `dotfile_outside_osa?/1` — five private copies of
  # logic that four sibling tools each also copied, and which had already
  # drifted apart. See `check_permissions/2` and `guard_write/2` above.

end
