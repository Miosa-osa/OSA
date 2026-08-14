defmodule OptimalSystemAgent.Tools.FileReadEofStampTest do
  @moduledoc """
  Every successful `file_read` states where the window ends.

  ## Why

  Measured on `schemelike-metacircular-eval`: 49 `file_read` calls against one
  path, each a *different* `offset`/`limit` window of the same growing file.
  Redundant-read suppression cannot touch that class — every one of those calls
  has different arguments and is, strictly, a new question. What was missing was
  the answer to the question the model was really asking, which is *"have I got
  all of it?"*.

  opencode ships no duplicate detector at all and measured zero duplicate calls
  on the same task. `tool/read.ts:344-350` always terminates the result with one
  of two stamps. This is that mechanism.

  The load-bearing assertions here are the ones about **which** stamp appears.
  A stamp that says "end of file" on a truncated window is worse than no stamp,
  because it converts a model that would have re-read into one that confidently
  reasons about a fragment.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    sid = "fr-stamp-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}
    path = Path.join(System.tmp_dir!(), "osa_stamp_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, path: path}
  end

  defp read(path, ctx, extra \\ %{}),
    do: FileRead.execute(Map.merge(%{"path" => path}, extra), ctx)

  defp lines(range), do: Enum.map_join(range, "", fn i -> "line#{i}\n" end)

  describe "a read that reached the end says so" do
    test "a whole-file read is stamped with the true line count", %{ctx: ctx, path: path} do
      File.write!(path, lines(1..12))

      assert {:ok, out} = read(path, ctx)
      assert out =~ "(End of file — 12 lines total)"
      refute out =~ "to continue"
    end

    test "a file with no trailing newline is not under-counted", %{ctx: ctx, path: path} do
      # `String.split(content, "\n")` yields a phantom "" for newline-terminated
      # content and the right answer here; a naive count gets exactly one of the
      # two cases right. Both are pinned.
      File.write!(path, "a\nb\nc")

      assert {:ok, out} = read(path, ctx)
      assert out =~ "(End of file — 3 lines total)"
    end

    test "a single-line file says line, not lines", %{ctx: ctx, path: path} do
      File.write!(path, "only\n")

      assert {:ok, out} = read(path, ctx)
      assert out =~ "(End of file — 1 line total)"
    end

    test "a window that runs off the end of the file is stamped EOF, not continue",
         %{ctx: ctx, path: path} do
      File.write!(path, lines(1..20))

      assert {:ok, out} = read(path, ctx, %{"offset" => 15, "limit" => 50})
      assert out =~ "line20"
      assert out =~ "(End of file — 20 lines total)"
      refute out =~ "to continue"
    end

    test "a window ending exactly on the last line is EOF, not a phantom continuation",
         %{ctx: ctx, path: path} do
      # The off-by-one that matters: `limit` lands precisely on EOF. Taking one
      # extra line is what distinguishes this from the case below, and getting
      # it wrong sends the model to an offset that does not exist.
      File.write!(path, lines(1..10))

      assert {:ok, out} = read(path, ctx, %{"offset" => 6, "limit" => 5})
      assert out =~ "line10"
      assert out =~ "(End of file — 10 lines total)"
      refute out =~ "to continue"
    end

    test "an offset with no limit reads to the end and is stamped EOF",
         %{ctx: ctx, path: path} do
      File.write!(path, lines(1..10))

      assert {:ok, out} = read(path, ctx, %{"offset" => 8})
      assert out =~ "(End of file — 10 lines total)"
    end
  end

  describe "a read that stopped short names the offset that continues it" do
    test "the continuation offset is the very next line", %{ctx: ctx, path: path} do
      File.write!(path, lines(1..100))

      assert {:ok, out} = read(path, ctx, %{"offset" => 1, "limit" => 10})
      assert out =~ "(Showing lines 1-10. Use offset=11 to continue.)"
      refute out =~ "End of file"
    end

    test "the named offset actually works, and the two windows do not overlap or gap",
         %{ctx: ctx, path: path} do
      File.write!(path, lines(1..30))

      assert {:ok, first} = read(path, ctx, %{"offset" => 1, "limit" => 10})
      assert [_, next] = Regex.run(~r/Use offset=(\d+) to continue/, first)

      assert {:ok, second} =
               read(path, ctx, %{"offset" => String.to_integer(next), "limit" => 10})

      # No gap: line 11 is the first line of the second window.
      assert second =~ "   11| line11"
      # No overlap: line 10 was the last line of the first window and is not
      # repeated.
      refute second =~ "line10\n"
      assert first =~ "   10| line10"
    end

    test "the extra line taken to decide the stamp is never rendered",
         %{ctx: ctx, path: path} do
      File.write!(path, lines(1..100))

      assert {:ok, out} = read(path, ctx, %{"offset" => 1, "limit" => 5})
      assert out =~ "   5| line5"
      # line6 was read to learn that more exists; showing it would silently
      # return limit+1 lines.
      refute out =~ "line6"
    end
  end

  describe "the stamp composes with redundant-read suppression rather than fighting it" do
    test "the suppression notice replaces the stamped result and does not restate the stamp",
         %{ctx: ctx, path: path} do
      # Big enough that suppression is worth making — see the notice's own
      # size guard.
      File.write!(path, lines(1..200))

      assert {:ok, first} = read(path, ctx)
      assert first =~ "(End of file — 200 lines total)"

      assert {:ok, second} = read(path, ctx)
      assert second =~ "is UNCHANGED since you last read it"
      # The stamp lives in the first result, which the notice points at. It is
      # not duplicated here, and neither is the file.
      refute second =~ "End of file"
      refute second =~ "line100"
    end

    test "a stamped read still satisfies read-before-edit", %{ctx: ctx, path: path} do
      File.write!(path, "alpha\nbeta\n")

      assert {:ok, out} = read(path, ctx)
      assert out =~ "End of file"

      assert :ok = FileState.check_read(ctx.session_id, path)
    end
  end

  describe "the stamp is a footer, not a rewrite of the content" do
    test "content and line numbering are byte-identical up to the stamp",
         %{ctx: ctx, path: path} do
      File.write!(path, lines(1..3))

      assert {:ok, out} = read(path, ctx, %{"offset" => 1, "limit" => 2})
      [body, stamp] = String.split(out, "\n(", parts: 2)

      assert body == "    1| line1\n    2| line2"
      assert "(" <> stamp =~ "Use offset=3 to continue"
    end

    test "the stamp costs a bounded, small number of bytes", %{ctx: ctx, path: path} do
      body = lines(1..500)
      File.write!(path, body)

      assert {:ok, out} = read(path, ctx)

      # Measured: 34 bytes for the EOF stamp on this file. The fence is here
      # because a stamp rides on EVERY successful read — it is the one addition
      # in this change-set that is a cost rather than a saving, and it has to
      # stay negligible against the content it annotates.
      assert byte_size(out) - byte_size(body) < 80
    end
  end
end
