defmodule OptimalSystemAgent.Tools.FileEditResultShapeTest do
  @moduledoc """
  What a successful `file_edit` reports back to the model.

  ## Why this changed

  `file_edit` used to answer an exact-match edit with a synthetic diff built
  from `old_string` and `new_string` — the two strings the model had just sent.
  Every edit was therefore paid for twice, outbound in the arguments and inbound
  in the result, and the second copy stayed in the transcript for the rest of the
  session. Measured on `schemelike-metacircular-eval`: 58 edits, median argument
  506 bytes. Measured on a 76-byte `old_string` here: 374 bytes of result, of
  which 335 was the echo.

  ## The line this draws

  The split is between *echo* and *information*, not between "verbose" and
  "terse":

    * **Exact match** — `old_string` was found verbatim. "It matched and was
      replaced" is the entire content of the result. Terse confirmation.
    * **Fuzzy match** — `old_string` did NOT appear verbatim; the
      line-endings/whitespace cascade picked a region that resembles it. What
      actually changed is new information and the model's only opportunity to
      catch an edit that landed somewhere it did not intend. The diff stays.

  The fuzzy assertions below are the load-bearing half. Dropping the diff there
  to save bytes would trade a correctness signal for a token saving, which is
  the wrong trade in a tool that mutates files.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    sid = "fe-shape-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}
    path = Path.join(System.tmp_dir!(), "osa_fe_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, path: path}
  end

  defp seed!(path, ctx, content) do
    File.write!(path, content)
    {:ok, _} = FileRead.execute(%{"path" => path}, ctx)
    :ok
  end

  defp edit(path, ctx, old, new, extra \\ %{}) do
    args = Map.merge(%{"path" => path, "old_string" => old, "new_string" => new}, extra)
    FileEdit.execute(args, ctx)
  end

  defp body(result), do: elem(result, 1)

  describe "an exact match confirms, and does not quote the arguments back" do
    test "the result is one line naming the file", %{ctx: ctx, path: path} do
      seed!(path, ctx, "alpha\nbeta\ngamma\n")

      result = edit(path, ctx, "beta", "BETA")
      assert :ok == elem(result, 0)
      assert body(result) == "Replaced in #{path}"
    end

    test "neither old_string nor new_string appears in the result", %{ctx: ctx, path: path} do
      seed!(path, ctx, "keep\nUNIQUE_OLD_MARKER\nkeep\n")

      result = edit(path, ctx, "UNIQUE_OLD_MARKER", "UNIQUE_NEW_MARKER")

      refute body(result) =~ "UNIQUE_OLD_MARKER"
      refute body(result) =~ "UNIQUE_NEW_MARKER"
    end

    test "no diff scaffolding is emitted", %{ctx: ctx, path: path} do
      seed!(path, ctx, "alpha\nbeta\ngamma\n")

      out = body(edit(path, ctx, "beta", "BETA"))

      refute out =~ "@@"
      refute out =~ "--- "
      refute out =~ "+++ "
    end

    test "the saving scales with the size of the edit, which is the point",
         %{ctx: ctx, path: path} do
      # A realistic edit at roughly OSA's measured median argument size.
      old = String.duplicate("the quick brown fox jumps over the lazy dog\n", 12)
      new = String.duplicate("the quick brown cat jumps over the lazy dog\n", 12)
      seed!(path, ctx, "header\n" <> old <> "footer\n")

      out = body(edit(path, ctx, old, new))

      # Result size is now independent of edit size: it is the path plus a dozen
      # characters, not a function of `old`/`new`.
      assert byte_size(out) < byte_size(path) + 20
      assert byte_size(out) < byte_size(old)
    end

    test "the edit still actually happened", %{ctx: ctx, path: path} do
      seed!(path, ctx, "alpha\nbeta\ngamma\n")
      assert :ok == elem(edit(path, ctx, "beta", "BETA"), 0)
      assert File.read!(path) == "alpha\nBETA\ngamma\n"
    end
  end

  describe "a fuzzy match keeps the diff, because there it is not an echo" do
    test "a line-ending-drifted match reports what changed and says it was fuzzy",
         %{ctx: ctx, path: path} do
      # CRLF on disk, LF in the request: the exact stage misses and the
      # `:line_endings` stage rescues it, so the region that changed is NOT the
      # bytes the model sent.
      seed!(path, ctx, "alpha\r\nindented_target\r\ngamma\r\n")

      result = edit(path, ctx, "indented_target\n", "replaced_target\n")
      assert :ok == elem(result, 0)

      out = body(result)
      assert out =~ "fuzzy"
      # The model asked for one thing and the matcher chose another region; the
      # diff is how it finds out.
      assert out =~ "@@"
      assert out =~ "indented_target"
    end
  end

  describe "structured metadata for the TUI is unaffected" do
    test "the 3-tuple still carries the real unified diff", %{ctx: ctx, path: path} do
      seed!(path, ctx, "alpha\nbeta\ngamma\n")

      assert {:ok, model_text, meta} = edit(path, ctx, "beta", "BETA")

      # The model gets the short string; the renderer still gets everything.
      assert model_text == "Replaced in #{path}"
      assert is_binary(meta.diff) and meta.diff != ""
      assert meta.diff =~ "beta"
      assert meta.diff =~ "BETA"
      assert meta.path == path
      assert is_map(meta.stats)
    end
  end

  describe "the other result shapes are unchanged" do
    test "replace_all over several sites reports the count, as before",
         %{ctx: ctx, path: path} do
      seed!(path, ctx, "x\nx\nx\n")

      out = body(edit(path, ctx, "x", "y", %{"replace_all" => true}))
      assert out =~ "Replaced 3 occurrences in #{path}"
    end

    test "a failed match still explains itself in full", %{ctx: ctx, path: path} do
      seed!(path, ctx, "alpha\nbeta\n")

      assert {:error, msg} = edit(path, ctx, "nowhere_in_this_file", "x")
      assert msg =~ "not found"
      assert msg =~ "Next step"
    end

    test "an already-applied edit still reports the no-op", %{ctx: ctx, path: path} do
      seed!(path, ctx, "alpha\nBETA\n")

      assert {:ok, msg} = edit(path, ctx, "beta_that_is_gone", "BETA")
      assert msg =~ "already applied"
    end
  end
end
