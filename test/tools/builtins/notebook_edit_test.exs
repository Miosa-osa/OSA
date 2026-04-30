defmodule OptimalSystemAgent.Tools.Builtins.NotebookEditTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.NotebookEdit.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  # ── Helpers ──────────────────────────────────────────────────────────

  setup do
    ctx = UseContext.empty()
    {:ok, ctx: ctx}
  end

  defp tmp_notebook(cells) do
    path = Path.join(System.tmp_dir!(), "nb_test_#{:erlang.unique_integer([:positive])}.ipynb")

    nb = %{
      "nbformat" => 4,
      "nbformat_minor" => 5,
      "metadata" => %{"language_info" => %{"name" => "python"}},
      "cells" => cells
    }

    File.write!(path, Jason.encode!(nb, pretty: true))
    path
  end

  defp code_cell(source), do: %{"cell_type" => "code", "source" => [source], "metadata" => %{}, "execution_count" => nil, "outputs" => []}
  defp md_cell(source), do: %{"cell_type" => "markdown", "source" => [source], "metadata" => %{}}

  defp read_cells(path) do
    path |> File.read!() |> Jason.decode!() |> Map.get("cells", [])
  end

  # ── validate/2 ───────────────────────────────────────────────────────

  describe "validate/2" do
    test "accepts valid action + path", %{ctx: ctx} do
      assert {:ok, _} = Handler.validate(%{"action" => "read", "path" => "/tmp/nb.ipynb"}, ctx)
    end

    test "rejects unknown action", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "explode", "path" => "/tmp/nb.ipynb"}, ctx)

      assert msg =~ "Unknown action"
    end

    test "rejects non-string action", %{ctx: ctx} do
      assert {:error, _, -32_602} =
               Handler.validate(%{"action" => 42, "path" => "/tmp/nb.ipynb"}, ctx)
    end

    test "rejects missing required params", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{}, ctx)
    end
  end

  # ── check_permissions/2 ──────────────────────────────────────────────

  describe "check_permissions/2" do
    test "denies path outside allowed read paths", %{ctx: ctx} do
      assert {:deny, _} =
               Handler.check_permissions(
                 %{"action" => "read", "path" => "/etc/passwd.ipynb"},
                 ctx
               )
    end

    test "denies non-.ipynb path", %{ctx: ctx} do
      assert {:deny, msg} =
               Handler.check_permissions(
                 %{"action" => "read", "path" => "/tmp/myfile.py"},
                 ctx
               )

      assert msg =~ ".ipynb"
    end

    test "allows read of .ipynb in /tmp", %{ctx: ctx} do
      assert {:allow, _} =
               Handler.check_permissions(
                 %{"action" => "read", "path" => "/tmp/notebook.ipynb"},
                 ctx
               )
    end

    test "denies write to blocked path", %{ctx: ctx} do
      assert {:deny, _} =
               Handler.check_permissions(
                 %{"action" => "add_cell", "path" => "/etc/evil.ipynb"},
                 ctx
               )
    end
  end

  # ── execute/2 — read ─────────────────────────────────────────────────

  describe "execute/2 — read" do
    test "returns cell listing with metadata for non-empty notebook", %{ctx: ctx} do
      path = tmp_notebook([code_cell("x = 1"), md_cell("# Title")])

      assert {:ok, result, %{cell_count: 2, path: ^path}} =
               Handler.execute(%{"action" => "read", "path" => path}, ctx)

      assert result =~ "[0] code"
      assert result =~ "[1] markdown"
    end

    test "returns empty message for notebook with no cells", %{ctx: ctx} do
      path = tmp_notebook([])

      assert {:ok, result, %{cell_count: 0}} =
               Handler.execute(%{"action" => "read", "path" => path}, ctx)

      assert result =~ "Empty notebook"
    end

    test "returns error for missing file", %{ctx: ctx} do
      assert {:error, msg} =
               Handler.execute(%{"action" => "read", "path" => "/tmp/nonexistent.ipynb"}, ctx)

      assert msg =~ "not found"
    end
  end

  # ── execute/2 — add_cell ─────────────────────────────────────────────

  describe "execute/2 — add_cell" do
    test "appends a code cell to the end by default", %{ctx: ctx} do
      path = tmp_notebook([code_cell("x = 1")])

      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "add_cell", "path" => path, "source" => "y = 2"},
                 ctx
               )

      assert msg =~ "Added code cell"
      cells = read_cells(path)
      assert length(cells) == 2
      assert List.last(cells)["cell_type"] == "code"
    end

    test "inserts a markdown cell at given position", %{ctx: ctx} do
      path = tmp_notebook([code_cell("a"), code_cell("b")])

      assert {:ok, _} =
               Handler.execute(
                 %{
                   "action" => "add_cell",
                   "path" => path,
                   "source" => "# Header",
                   "cell_type" => "markdown",
                   "position" => 1
                 },
                 ctx
               )

      cells = read_cells(path)
      assert length(cells) == 3
      assert Enum.at(cells, 1)["cell_type"] == "markdown"
    end
  end

  # ── execute/2 — edit_cell ────────────────────────────────────────────

  describe "execute/2 — edit_cell" do
    test "edits source of existing cell", %{ctx: ctx} do
      path = tmp_notebook([code_cell("original")])

      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "edit_cell", "path" => path, "index" => 0, "source" => "updated"},
                 ctx
               )

      assert msg =~ "Edited cell [0]"
      [cell] = read_cells(path)
      assert Enum.join(cell["source"]) =~ "updated"
    end

    test "returns error for out-of-range index", %{ctx: ctx} do
      path = tmp_notebook([code_cell("x")])

      assert {:error, msg} =
               Handler.execute(
                 %{"action" => "edit_cell", "path" => path, "index" => 5, "source" => "y"},
                 ctx
               )

      assert msg =~ "out of range"
    end

    test "returns error when index is missing", %{ctx: ctx} do
      path = tmp_notebook([code_cell("x")])

      assert {:error, msg} =
               Handler.execute(%{"action" => "edit_cell", "path" => path, "source" => "y"}, ctx)

      assert msg =~ "index"
    end
  end

  # ── execute/2 — delete_cell ──────────────────────────────────────────

  describe "execute/2 — delete_cell" do
    test "removes the specified cell", %{ctx: ctx} do
      path = tmp_notebook([code_cell("first"), code_cell("second")])

      assert {:ok, msg} =
               Handler.execute(%{"action" => "delete_cell", "path" => path, "index" => 0}, ctx)

      assert msg =~ "Deleted cell [0]"
      cells = read_cells(path)
      assert length(cells) == 1
      assert Enum.join(Enum.at(cells, 0)["source"]) =~ "second"
    end
  end

  # ── execute/2 — move_cell ────────────────────────────────────────────

  describe "execute/2 — move_cell" do
    test "moves a cell to a new position", %{ctx: ctx} do
      path = tmp_notebook([code_cell("A"), code_cell("B"), code_cell("C")])

      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "move_cell", "path" => path, "index" => 2, "position" => 0},
                 ctx
               )

      assert msg =~ "Moved cell"
      [first | _] = read_cells(path)
      assert Enum.join(first["source"]) =~ "C"
    end

    test "returns error when position is missing", %{ctx: ctx} do
      path = tmp_notebook([code_cell("A"), code_cell("B")])

      assert {:error, msg} =
               Handler.execute(%{"action" => "move_cell", "path" => path, "index" => 0}, ctx)

      assert msg =~ "position"
    end
  end

  # ── Tool callbacks ────────────────────────────────────────────────────

  describe "Tool callbacks" do
    test "name and metadata" do
      assert Tool.name() == "notebook_edit"
      assert "notebook_read" in Tool.aliases()
      assert Tool.should_defer?()
      refute Tool.always_load?()
      assert Tool.safety() == :write_safe
    end

    test "read_only? is true only for read action" do
      ctx = UseContext.empty()
      assert Tool.read_only?(%{"action" => "read"}, ctx)
      refute Tool.read_only?(%{"action" => "add_cell"}, ctx)
      refute Tool.read_only?(%{"action" => "edit_cell"}, ctx)
    end

    test "destructive? is true only for delete_cell" do
      ctx = UseContext.empty()
      assert Tool.destructive?(%{"action" => "delete_cell"}, ctx)
      refute Tool.destructive?(%{"action" => "read"}, ctx)
      refute Tool.destructive?(%{"action" => "add_cell"}, ctx)
    end

    test "concurrency_safe? is always false" do
      ctx = UseContext.empty()
      refute Tool.concurrency_safe?(%{}, ctx)
    end

    test "parameters schema includes all actions" do
      schema = Tool.parameters()
      action_enum = get_in(schema, ["properties", "action", "enum"])
      assert "read" in action_enum
      assert "add_cell" in action_enum
      assert "edit_cell" in action_enum
      assert "delete_cell" in action_enum
      assert "move_cell" in action_enum
    end
  end
end
