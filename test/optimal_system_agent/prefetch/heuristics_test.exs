defmodule OptimalSystemAgent.Prefetch.HeuristicsTest do
  @moduledoc """
  Candidate generation is a hint generator, not a claim — every assertion
  here is either "this obviously-real path became a candidate" or "this
  obviously-fake/dangerous one did not", never "the model will definitely
  ask for this next".
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Prefetch.Heuristics

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, dir: dir}
  end

  describe "candidates_from_text/2" do
    test "extracts an existing path mentioned in streamed text", %{dir: dir} do
      path = Path.join(dir, "lib/foo.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "defmodule Foo do\nend\n")

      text = "I'll read lib/foo.ex next to see how it's structured."
      [candidate] = Heuristics.candidates_from_text(text, dir)

      assert candidate.tool == "file_read"
      assert candidate.args["path"] == Path.expand(path)
    end

    test "drops a path-looking token that does not exist on disk", %{dir: dir} do
      text = "Checking lib/does_not_exist.ex for context."
      assert Heuristics.candidates_from_text(text, dir) == []
    end

    test "ignores prose with no path-shaped token", %{dir: dir} do
      text = "Let me think about this for a second before doing anything."
      assert Heuristics.candidates_from_text(text, dir) == []
    end

    test "caps the number of candidates from one scan", %{dir: dir} do
      paths =
        for n <- 1..10 do
          p = Path.join(dir, "file_#{n}.ex")
          File.write!(p, "x")
          "file_#{n}.ex"
        end

      text = Enum.join(paths, " and ")
      candidates = Heuristics.candidates_from_text(text, dir)

      assert length(candidates) <= 6
    end

    test "non-binary input never raises" do
      assert Heuristics.candidates_from_text(nil, "/tmp") == []
    end
  end

  describe "sibling_candidates/1" do
    test "returns existing sibling files, excluding the edited one and dotfiles", %{dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "a")
      File.write!(Path.join(dir, "b.ex"), "b")
      File.write!(Path.join(dir, ".hidden"), "h")
      File.mkdir_p!(Path.join(dir, "subdir"))

      edited = Path.join(dir, "a.ex")
      candidates = Heuristics.sibling_candidates(edited)
      paths = Enum.map(candidates, & &1.args["path"])

      assert Path.join(dir, "b.ex") in paths
      refute Path.join(dir, "a.ex") in paths
      refute Enum.any?(paths, &String.ends_with?(&1, ".hidden"))
      refute Enum.any?(paths, &String.ends_with?(&1, "subdir"))
    end

    test "an edited file in a directory that cannot be listed returns no candidates" do
      assert Heuristics.sibling_candidates("/nonexistent-#{System.unique_integer()}/x.ex") == []
    end
  end

  describe "test_file_candidates/1" do
    test "lib module maps to its test file when it exists", %{dir: dir} do
      lib = Path.join(dir, "lib/my_app/foo.ex")
      test = Path.join(dir, "test/my_app/foo_test.exs")
      File.mkdir_p!(Path.dirname(lib))
      File.mkdir_p!(Path.dirname(test))
      File.write!(lib, "defmodule Foo do\nend\n")
      File.write!(test, "defmodule FooTest do\nend\n")

      [candidate] = Heuristics.test_file_candidates(lib)
      assert candidate.args["path"] == Path.expand(test)
    end

    test "test file maps back to its lib module when it exists", %{dir: dir} do
      lib = Path.join(dir, "lib/my_app/foo.ex")
      test = Path.join(dir, "test/my_app/foo_test.exs")
      File.mkdir_p!(Path.dirname(lib))
      File.mkdir_p!(Path.dirname(test))
      File.write!(lib, "x")
      File.write!(test, "x")

      [candidate] = Heuristics.test_file_candidates(test)
      assert candidate.args["path"] == Path.expand(lib)
    end

    test "python module maps to test_<name>.py when it exists", %{dir: dir} do
      lib = Path.join(dir, "pkg/foo.py")
      test = Path.join(dir, "pkg/test_foo.py")
      File.mkdir_p!(Path.dirname(lib))
      File.write!(lib, "x")
      File.write!(test, "x")

      [candidate] = Heuristics.test_file_candidates(lib)
      assert candidate.args["path"] == Path.expand(test)
    end

    test "returns nothing when the derived test file does not exist", %{dir: dir} do
      lib = Path.join(dir, "lib/my_app/lonely.ex")
      File.mkdir_p!(Path.dirname(lib))
      File.write!(lib, "x")

      assert Heuristics.test_file_candidates(lib) == []
    end
  end

  describe "classify_write/2" do
    test "a provably read-only shell command changes nothing" do
      assert Heuristics.classify_write("shell_execute", %{"command" => "git status"}) == :none
    end

    test "a non-read-only shell command is repo-wide" do
      assert Heuristics.classify_write("shell_execute", %{"command" => "rm -rf /tmp/x"}) ==
               :repo_wide
    end

    test "file_write pins down its target path" do
      assert Heuristics.classify_write("file_write", %{"path" => "/tmp/a.ex"}) ==
               {:paths, ["/tmp/a.ex"]}
    end

    test "file_edit with no recognisable path falls back to repo-wide" do
      assert Heuristics.classify_write("file_edit", %{}) == :repo_wide
    end

    test "multi_file_edit collects every edit's target path" do
      args = %{"edits" => [%{"path" => "/tmp/a.ex"}, %{"path" => "/tmp/b.ex"}]}
      assert {:paths, paths} = Heuristics.classify_write("multi_file_edit", args)
      assert Enum.sort(paths) == ["/tmp/a.ex", "/tmp/b.ex"]
    end

    test "file_move collects both source and destination" do
      args = %{"source" => "/tmp/old.ex", "destination" => "/tmp/new.ex"}
      assert {:paths, paths} = Heuristics.classify_write("file_move", args)
      assert Enum.sort(paths) == ["/tmp/new.ex", "/tmp/old.ex"]
    end

    test "git tool calls are always repo-wide" do
      assert Heuristics.classify_write("git", %{"command" => "commit"}) == :repo_wide
    end

    test "a read-only tool changes nothing" do
      assert Heuristics.classify_write("file_read", %{"path" => "/tmp/a.ex"}) == :none
      assert Heuristics.classify_write("dir_list", %{"path" => "/tmp"}) == :none
    end
  end
end
