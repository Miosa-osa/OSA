defmodule OptimalSystemAgent.Tools.Builtins.RepoMapTest do
  @moduledoc """
  The `repo_map` tool — the cheap consult path for the live repo model.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.RepoMap
  alias OptimalSystemAgent.Tools.Builtins.RepoMap, as: RepoMapTool

  defp git!(dir, args) do
    System.cmd("git", args,
      cd: dir,
      env: [
        {"GIT_AUTHOR_NAME", "Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"}
      ]
    )
  end

  defp tmp_repo do
    dir = Path.join(System.tmp_dir!(), "repo-map-tool-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(
      Path.join(dir, "lib/foo.ex"),
      "defmodule Foo do\n  def bar(a) do\n    a\n  end\nend\n"
    )

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "first"])
    dir
  end

  setup do
    dir = tmp_repo()

    on_exit(fn ->
      File.rm_rf(dir)
      RepoMap.invalidate(Path.expand(dir))
    end)

    {:ok, dir: dir}
  end

  describe "identity" do
    test "name is repo_map" do
      assert RepoMapTool.name() == "repo_map"
    end

    test "safety is read_only" do
      assert RepoMapTool.safety() == :read_only
    end

    test "is deferred (not in the always-loaded default toolbox)" do
      assert RepoMapTool.should_defer?() == true
    end

    test "no action is required" do
      assert RepoMapTool.parameters()["required"] == []
    end
  end

  describe "execute/1 — summary (default)" do
    test "mentions file count and the branch", %{dir: dir} do
      assert {:ok, out} = RepoMapTool.execute(%{"path" => dir})
      assert out =~ "files tracked"
      assert out =~ "main@"
    end
  end

  describe "execute/1 — tree" do
    test "lists tracked files", %{dir: dir} do
      assert {:ok, out} = RepoMapTool.execute(%{"path" => dir, "action" => "tree"})
      assert out =~ "foo.ex"
      assert out =~ "lib/"
    end
  end

  describe "execute/1 — symbols" do
    test "returns the cached outline for one file", %{dir: dir} do
      assert {:ok, out} =
               RepoMapTool.execute(%{
                 "path" => dir,
                 "action" => "symbols",
                 "file" => "lib/foo.ex"
               })

      assert out =~ "[module] Foo"
      assert out =~ "[function] bar/1"
    end

    test "requires a file parameter", %{dir: dir} do
      assert {:error, msg} = RepoMapTool.execute(%{"path" => dir, "action" => "symbols"})
      assert msg =~ "requires a \"file\""
    end

    test "a file outside the tree is a clear error", %{dir: dir} do
      assert {:error, msg} =
               RepoMapTool.execute(%{"path" => dir, "action" => "symbols", "file" => "nope.ex"})

      assert msg =~ "not in the repo map"
    end
  end

  describe "execute/1 — git_state" do
    test "renders branch, HEAD, and a clean working tree", %{dir: dir} do
      assert {:ok, out} = RepoMapTool.execute(%{"path" => dir, "action" => "git_state"})
      assert out =~ "Branch: main"
      assert out =~ "HEAD:"
      assert out =~ "clean"
    end

    test "renders dirty files when the tree has changes", %{dir: dir} do
      File.write!(Path.join(dir, "lib/foo.ex"), "changed\n")

      assert {:ok, out} =
               RepoMapTool.execute(%{"path" => dir, "action" => "git_state", "refresh" => true})

      assert out =~ "1 dirty file"
      assert out =~ "foo.ex"
    end
  end

  describe "execute/1 — test_status" do
    test "says no test run has been observed yet", %{dir: dir} do
      assert {:ok, out} = RepoMapTool.execute(%{"path" => dir, "action" => "test_status"})
      assert out =~ "No test run has been observed"
    end

    test "reflects an observed test run", %{dir: dir} do
      _ = RepoMapTool.execute(%{"path" => dir})

      RepoMap.observe_tool_result(
        dir,
        "shell_execute",
        %{"command" => "mix test"},
        "3 tests, 1 failure\n"
      )

      assert {:ok, out} = RepoMapTool.execute(%{"path" => dir, "action" => "test_status"})
      assert out =~ "FAILED"
      assert out =~ "1 failure"
    end
  end

  describe "execute/1 — errors" do
    test "an unknown action is refused clearly", %{dir: dir} do
      assert {:error, msg} = RepoMapTool.execute(%{"path" => dir, "action" => "bogus"})
      assert msg =~ "Unknown action"
    end

    test "a non-existent path is refused" do
      assert {:error, msg} = RepoMapTool.execute(%{"path" => "/definitely/not/a/real/dir"})
      assert msg =~ "not a directory"
    end
  end
end
