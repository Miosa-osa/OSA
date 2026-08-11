defmodule OptimalSystemAgent.Tools.RecoveryPathsTest do
  @moduledoc """
  Failure modes that used to DEAD-END the agent.

  Each case below is one where the tool's answer was either unrecoverable (no
  retry could ever succeed) or silently wrong (a confident answer to a question
  that was never asked). Both cost whole tasks, not just a turn.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileGrep.Handler, as: FileGrep
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    DriftGuard.reset()

    sid = "recovery-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}

    dir = Path.join(System.tmp_dir!(), "osa_recovery_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ctx: ctx, dir: dir}
  end

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp read(path, ctx), do: FileRead.execute(%{"path" => path}, ctx)

  defp edit(path, old, new, ctx, opts \\ []) do
    FileEdit.execute(
      %{
        "path" => path,
        "old_string" => old,
        "new_string" => new,
        "replace_all" => Keyword.get(opts, :replace_all, false)
      },
      ctx
    )
  end

  # ══════════════════════════════════════════════════════════════════════
  # file_edit — an already-applied edit is idempotent, not fatal
  # ══════════════════════════════════════════════════════════════════════

  describe "file_edit re-application" do
    test "re-running an edit that already landed succeeds as a no-op", %{ctx: ctx, dir: dir} do
      path = write!(dir, "a.ex", "defmodule A do\n  def go, do: :old\nend\n")
      {:ok, _} = read(path, ctx)

      assert {:ok, _, _} = edit(path, "do: :old", "do: :new", ctx)

      # BEFORE: this retry returned {:error, "old_string not found"} — and would
      # do so on every subsequent retry too, forever, because the file is
      # already in the requested state. The agent could not get past it.
      {:ok, _} = read(path, ctx)
      assert {:ok, msg} = edit(path, "do: :old", "do: :new", ctx)
      assert msg =~ "already applied"
      assert msg =~ "continue with the next step"

      # The file is untouched by the no-op.
      assert File.read!(path) == "defmodule A do\n  def go, do: :new\nend\n"
    end

    test "a genuinely missing old_string still fails, with a next step", %{ctx: ctx, dir: dir} do
      path = write!(dir, "b.ex", "hello world\n")
      {:ok, _} = read(path, ctx)

      assert {:error, msg} = edit(path, "nowhere to be found", "replacement", ctx)
      assert msg =~ "old_string not found"
      assert msg =~ "Next step:"
      assert msg =~ "file_read"
    end

    test "a failed DELETION is never laundered into success", %{ctx: ctx, dir: dir} do
      # new_string == "" is vacuously "present" in every file. Treating that as
      # already-applied would swallow every failed deletion, so deletions keep
      # the hard error.
      path = write!(dir, "c.ex", "keep this line\n")
      {:ok, _} = read(path, ctx)

      assert {:error, msg} = edit(path, "line that is not there", "", ctx)
      assert msg =~ "old_string not found"
      assert File.read!(path) == "keep this line\n"
    end

    test "the no-op path does not bypass the read-before-edit guard", %{dir: dir} do
      # A fresh session that never read the file must still be rejected, even
      # though the target state already holds.
      path = write!(dir, "d.ex", "already new\n")

      fresh = %UseContext{
        session_id: "never-read-#{System.unique_integer()}",
        permission_tier: :full
      }

      assert {:error, _} = edit(path, "already old", "already new", fresh)
    end
  end

  describe "file_edit ambiguity" do
    test "an ambiguous match reports WHERE the candidates are", %{ctx: ctx, dir: dir} do
      path =
        write!(dir, "dup.ex", """
        def go, do: :x
        other
        def go, do: :x
        more
        def go, do: :x
        """)

      {:ok, _} = read(path, ctx)

      assert {:error, msg} = edit(path, "def go, do: :x", "def go, do: :y", ctx)

      assert msg =~ "found 3 times"
      # BEFORE: the count only. The matcher already knows the locations; the
      # agent had to re-read and hunt for them itself.
      assert msg =~ "Candidate locations (line numbers): 1, 3, 5"
      assert msg =~ "Next step:"
      assert msg =~ "replace_all"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # file_grep — a bad path is an ERROR, not "no matches"
  # ══════════════════════════════════════════════════════════════════════

  describe "file_grep path validation" do
    test "a nonexistent path errors instead of answering 'No matches found.'", %{
      ctx: ctx,
      dir: dir
    } do
      missing = Path.join(dir, "does_not_exist")

      # BEFORE: {:ok, "No matches found."} — a confident WRONG answer. ripgrep
      # exits 1 both for "no match" and for "no such path", and the Elixir
      # fallback globs an absent directory into []. The agent concluded the
      # symbol did not exist and followed a false trail.
      assert {:error, msg} = FileGrep.execute(%{"pattern" => "anything", "path" => missing}, ctx)

      assert msg =~ "Search path does not exist"
      assert msg =~ "NOT the same as 'no matches'"
      assert msg =~ "Next step:"
    end

    test "a typo'd path names the near misses under its real parent", %{ctx: ctx, dir: dir} do
      File.mkdir_p!(Path.join(dir, "handlers"))
      typo = Path.join(dir, "handers")

      assert {:error, msg} = FileGrep.execute(%{"pattern" => "x", "path" => typo}, ctx)
      assert msg =~ "similarly-named entries"
      assert msg =~ "handlers"
    end

    test "an existing path with no match still reports no matches", %{ctx: ctx, dir: dir} do
      write!(dir, "e.txt", "nothing interesting\n")

      assert {:ok, out} =
               FileGrep.execute(%{"pattern" => "zzz_no_such_token_zzz", "path" => dir}, ctx)

      assert out =~ "No matches found."
    end

    test "an existing path WITH a match is unaffected", %{ctx: ctx, dir: dir} do
      write!(dir, "f.txt", "needle in here\n")

      assert {:ok, out} = FileGrep.execute(%{"pattern" => "needle", "path" => dir}, ctx)
      assert out =~ "needle"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # tool output truncation — a pointer, not a dead end
  # ══════════════════════════════════════════════════════════════════════

  describe "tool output overflow" do
    test "output over the cap is spilled to disk with a ready file_read call" do
      big = Enum.map_join(1..5_000, "\n", fn i -> "line #{i} of output" end)
      limit = 2_000

      out = ToolExecutor.spill_or_truncate(big, limit, %{name: "shell_execute", id: "call_1"})

      # BEFORE: the tail past `limit` was dropped with no way back to it.
      assert out =~ "The COMPLETE output is saved at"
      assert out =~ "Next step: read the rest with file_read"
      assert out =~ ~s("offset":)

      [path] = Regex.run(~r{saved at (\S+)\.}, out, capture: :all_but_first)
      assert File.read!(path) == big
      on_exit(fn -> File.rm(path) end)

      # The message itself still respects the cap.
      assert byte_size(out) < limit + 800
    end

    test "the offset points at the first line NOT shown" do
      big = Enum.map_join(1..5_000, "\n", fn i -> "line #{i}" end)

      out = ToolExecutor.spill_or_truncate(big, 2_000, %{name: "t", id: "c"})

      [path, offset] =
        Regex.run(~r{saved at (\S+)\..*"offset": (\d+)}s, out, capture: :all_but_first)

      on_exit(fn -> File.rm(path) end)

      offset = String.to_integer(offset)
      head = out |> String.split("\n\n[Output truncated") |> List.first()

      # Lines 1..N were shown; the next unread line is N+1.
      assert offset == length(String.split(head, "\n")) + 1
      # And that line really is the continuation.
      assert Enum.at(String.split(big, "\n"), offset - 1) == "line #{offset}"
    end

    test "the spill is content-hashed, so a replay reuses one file" do
      big = String.duplicate("x", 40_000)
      call = %{name: "t", id: "c"}

      a = ToolExecutor.spill_or_truncate(big, 1_000, call)
      b = ToolExecutor.spill_or_truncate(big, 1_000, %{name: "t", id: "different_id"})

      [pa] = Regex.run(~r{saved at (\S+)\.}, a, capture: :all_but_first)
      [pb] = Regex.run(~r{saved at (\S+)\.}, b, capture: :all_but_first)

      assert pa == pb
      on_exit(fn -> File.rm(pa) end)
    end

    test "output within the cap is returned byte-identical" do
      small = "just a little output\n"
      assert ToolExecutor.spill_or_truncate(small, 10_240, %{name: "t", id: "c"}) == small
    end

    test "the head is always valid UTF-8 even when the cut lands mid-grapheme" do
      # binary_part/3 can split a multi-byte character; some providers reject
      # the resulting invalid UTF-8 outright, losing the whole turn.
      big = String.duplicate("é", 5_000)

      out = ToolExecutor.spill_or_truncate(big, 1_001, %{name: "t", id: "c"})
      assert String.valid?(out)

      [path] = Regex.run(~r{saved at (\S+)\.}, out, capture: :all_but_first)
      on_exit(fn -> File.rm(path) end)
    end
  end
end
