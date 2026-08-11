defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.FormatAndGuardTest do
  @moduledoc """
  Finding 4: `notebook_edit` rewrote every key of every cell on every edit while
  its moduledoc claimed it preserved field order, and it had no read-before-edit
  guard at all.

  Every test here fails against the pre-fix tree.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.NotebookEdit.Handler
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  @notebook """
  {
   "cells": [
    {
     "cell_type": "code",
     "execution_count": 1,
     "metadata": {},
     "outputs": [],
     "source": [
      "print('hello')"
     ]
    }
   ],
   "metadata": {
    "kernelspec": {
     "display_name": "Python 3",
     "language": "python",
     "name": "python3"
    }
   },
   "nbformat": 4,
   "nbformat_minor": 5
  }
  """

  setup do
    FileState.reset()
    dir = Path.join(System.tmp_dir!(), "osa_nb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "book.ipynb")
    File.write!(path, @notebook)

    session = "nb-#{System.unique_integer([:positive])}"
    {:ok, path: path, session: session, ctx: %UseContext{session_id: session}}
  end

  describe "on-disk format (handler.ex:210)" do
    test "keys keep a deterministic nbformat order and one-space indent", %{
      path: path,
      session: session,
      ctx: ctx
    } do
      FileState.record_read(session, path)

      assert {:ok, _} =
               Handler.execute(
                 %{"action" => "edit_cell", "path" => path, "index" => 0, "source" => "print(1)"},
                 ctx
               )

      written = File.read!(path)

      # Jupyter (nbformat) writes sort_keys=True, indent=1. `pretty: true`
      # indents with TWO spaces, and Elixir maps have no key order at all, so
      # every key of every cell moved on every edit and a one-cell change
      # rewrote the whole file.
      assert written =~ ~s( "cells": [)
      refute written =~ ~s(  "cells": [)

      keys =
        Regex.scan(~r/^ "([a-z_]+)":/m, written)
        |> Enum.map(fn [_, k] -> k end)

      assert keys == Enum.sort(keys)
      assert keys == ["cells", "metadata", "nbformat", "nbformat_minor"]

      # Cell keys are sorted too.
      cell_keys =
        Regex.scan(~r/^     "([a-z_]+)":/m, written)
        |> Enum.map(fn [_, k] -> k end)

      assert cell_keys == Enum.sort(cell_keys)
    end

    test "the output is stable: editing twice with the same content is a no-op diff", %{
      path: path,
      session: session,
      ctx: ctx
    } do
      FileState.record_read(session, path)

      assert {:ok, _} =
               Handler.execute(
                 %{"action" => "edit_cell", "path" => path, "index" => 0, "source" => "print(1)"},
                 ctx
               )

      first = File.read!(path)

      assert {:ok, _} =
               Handler.execute(
                 %{"action" => "edit_cell", "path" => path, "index" => 0, "source" => "print(1)"},
                 ctx
               )

      assert File.read!(path) == first
    end

    test "unknown fields survive", %{path: path, session: session, ctx: ctx} do
      nb = path |> File.read!() |> Jason.decode!() |> Map.put("x_custom", %{"keep" => true})
      File.write!(path, Jason.encode!(nb))
      FileState.record_read(session, path)

      assert {:ok, _} =
               Handler.execute(
                 %{"action" => "edit_cell", "path" => path, "index" => 0, "source" => "z"},
                 ctx
               )

      assert %{"x_custom" => %{"keep" => true}} = path |> File.read!() |> Jason.decode!()
    end
  end

  describe "read-before-edit (handler.ex — absent pre-fix)" do
    test "editing a notebook that was never read is refused", %{path: path, ctx: ctx} do
      # Its three siblings all have this guard. Without it, a cell index taken
      # from a stale reading deletes or overwrites the wrong cell.
      assert {:error, message} =
               Handler.execute(
                 %{"action" => "delete_cell", "path" => path, "index" => 0},
                 ctx
               )

      assert message =~ "read" or message =~ "stale"
      # Nothing was written.
      assert File.read!(path) == @notebook
    end

    test "reading the notebook first satisfies the guard", %{path: path, ctx: ctx} do
      assert {:ok, _, %{cell_count: 1}} =
               Handler.execute(%{"action" => "read", "path" => path}, ctx)

      assert {:ok, _} =
               Handler.execute(
                 %{"action" => "delete_cell", "path" => path, "index" => 0},
                 ctx
               )

      assert %{"cells" => []} = path |> File.read!() |> Jason.decode!()
    end
  end

  describe "write sandbox (handler.ex — private copy pre-fix)" do
    test "a notebook reached through a directory symlink is refused", %{ctx: ctx} do
      dir = Path.join(System.tmp_dir!(), "osa_nb_link_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      link = Path.join(dir, "escape")
      File.ln_s!("/etc", link)

      try do
        assert {:deny, _} =
                 Handler.check_permissions(
                   %{"action" => "edit_cell", "path" => Path.join(link, "x.ipynb")},
                   ctx
                 )
      after
        File.rm_rf!(dir)
      end
    end
  end
end
