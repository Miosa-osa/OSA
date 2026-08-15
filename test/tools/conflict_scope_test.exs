defmodule OptimalSystemAgent.Tools.ConflictScopeTest do
  @moduledoc """
  `download` declared `concurrency_safe? true` with the comment "multiple
  downloads to *different* paths are safe" — a statement about a PAIR, made by
  a predicate that only ever sees one call. Two downloads to one path were
  therefore dispatched concurrently: last write wins, both report success.

  `ConflictScope` is the cross-call answer. These tests pin the two properties
  the whole thing rests on: the conflict matrix, and — the load-bearing half —
  that two different SPELLINGS of one path are recognised as one path.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.ConflictScope

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp download(path), do: ConflictScope.for_call("download", %{"path" => path}, true)
  defp edit(path), do: ConflictScope.for_call("file_edit", %{"path" => path}, false)
  defp read(path), do: ConflictScope.for_call("file_read", %{"path" => path}, true)

  describe "the conflict matrix" do
    test "two downloads to ONE path conflict", %{dir: dir} do
      p = Path.join(dir, "same.bin")
      assert ConflictScope.conflict?(download(p), download(p))
    end

    test "two downloads to DIFFERENT paths do not — the win that forcing false would cost",
         %{dir: dir} do
      a = download(Path.join(dir, "a.bin"))
      b = download(Path.join(dir, "b.bin"))

      assert a.mode == :scoped
      assert b.mode == :scoped
      refute ConflictScope.conflict?(a, b)
    end

    test "a write and a read of the same file conflict", %{dir: dir} do
      p = Path.join(dir, "f.txt")
      assert ConflictScope.conflict?(edit(p), read(p))
      assert ConflictScope.conflict?(read(p), edit(p))
    end

    test "two reads of the same file do not", %{dir: dir} do
      p = Path.join(dir, "f.txt")
      refute ConflictScope.conflict?(read(p), read(p))
    end

    test "a barrier conflicts with everything, including another barrier", %{dir: dir} do
      barrier = ConflictScope.for_call("shell_execute", %{"command" => "ls"}, false)

      assert barrier.mode == :barrier
      assert ConflictScope.conflict?(barrier, download(Path.join(dir, "a.bin")))
      assert ConflictScope.conflict?(download(Path.join(dir, "a.bin")), barrier)
      assert ConflictScope.conflict?(barrier, barrier)
    end

    test "a parallel-safe call with nothing to declare conflicts with nothing but a barrier" do
      p = ConflictScope.for_call("web_search", %{"query" => "x"}, true)
      assert p.mode == :parallel
      refute ConflictScope.conflict?(p, p)
      assert ConflictScope.conflict?(p, ConflictScope.for_call("git", %{}, false))
    end

    test "multi_file_edit conflicts on ANY shared target", %{dir: dir} do
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")
      c = Path.join(dir, "c.ex")

      two =
        ConflictScope.for_call(
          "multi_file_edit",
          %{"edits" => [%{"path" => a}, %{"path" => b}]},
          false
        )

      assert two.mode == :scoped
      assert ConflictScope.conflict?(two, edit(b))
      refute ConflictScope.conflict?(two, edit(c))
    end
  end

  describe "an undecidable call is a barrier, never a guess" do
    test "a path-scoped tool with no path at all" do
      assert ConflictScope.for_call("download", %{"url" => "https://x"}, true).mode == :barrier
      assert ConflictScope.for_call("file_edit", %{}, false).mode == :barrier
    end

    test "a multi-target write with one unreadable entry" do
      scope =
        ConflictScope.for_call(
          "multi_file_edit",
          %{"edits" => [%{"path" => "/tmp/a"}, %{"old_string" => "no path here"}]},
          false
        )

      assert scope.mode == :barrier
    end

    test "an unknown tool keeps its own fail-closed answer" do
      assert ConflictScope.for_call("never_heard_of_it", %{}, false).mode == :barrier
      assert ConflictScope.for_call("never_heard_of_it", %{}, true).mode == :parallel
    end
  end

  describe "normalisation — the load-bearing half" do
    test "a relative and an absolute path to one file are not distinct" do
      # `file_edit` roots relatives at the process cwd, mirroring
      # `Path.expand/1` in its own handler.
      rel = edit("mix.exs")
      abs = edit(Path.expand("mix.exs"))

      assert ConflictScope.conflict?(rel, abs),
             "a relative and an absolute name for one file compared as different files"
    end

    test "a download's relative path is rooted where the HANDLER roots it" do
      # `~/.osa/workspace`, not the cwd. Rooting it anywhere else would make a
      # colliding pair look disjoint.
      rel = download("report.pdf")
      abs = download(Path.expand("~/.osa/workspace/report.pdf"))

      assert ConflictScope.conflict?(rel, abs)
      refute ConflictScope.conflict?(rel, download(Path.expand("report.pdf")))
    end

    test "a symlink and its target are one file", %{dir: dir} do
      real_dir = Path.join(dir, "real")
      File.mkdir_p!(real_dir)
      target = Path.join(real_dir, "f.txt")
      File.write!(target, "x")

      link_dir = Path.join(dir, "link")

      case File.ln_s(real_dir, link_dir) do
        :ok ->
          via_link = Path.join(link_dir, "f.txt")

          assert ConflictScope.conflict?(edit(via_link), edit(target)),
                 "a symlinked path and its target compared as different files"

        {:error, reason} ->
          # Windows / restricted filesystems. Say so rather than passing silently.
          IO.puts("skipping symlink assertion: #{inspect(reason)}")
      end
    end

    test "`.` and `..` segments collapse", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "sub"))
      direct = Path.join(dir, "f.txt")
      indirect = Path.join([dir, "sub", "..", "f.txt"])

      assert ConflictScope.conflict?(edit(direct), edit(indirect))
    end
  end

  describe "kill switch" do
    test "disabling it reverts every call to the per-call answer", %{dir: dir} do
      prior = Application.get_env(:optimal_system_agent, :cross_call_conflict_detection)
      Application.put_env(:optimal_system_agent, :cross_call_conflict_detection, false)

      on_exit(fn ->
        Application.put_env(:optimal_system_agent, :cross_call_conflict_detection, prior)
      end)

      # Two downloads to different paths become plain `:parallel` again —
      # which is the OLD, wrong behaviour, restored deliberately and only here.
      assert download(Path.join(dir, "a.bin")).mode == :parallel
      assert edit(Path.join(dir, "a.txt")).mode == :barrier
    end
  end
end
