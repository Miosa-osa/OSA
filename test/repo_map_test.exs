defmodule OptimalSystemAgent.RepoMapTest do
  @moduledoc """
  The live repo model: file tree + per-file symbols + test status + git
  state, cached per workspace root and updated incrementally rather than
  rescanned from zero on every consult.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.RepoMap

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
    dir = Path.join(System.tmp_dir!(), "repo-map-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(
      Path.join(dir, "lib/foo.ex"),
      "defmodule Foo do\n  def bar(a) do\n    a\n  end\nend\n"
    )

    File.write!(Path.join(dir, "README.md"), "# hi\n")
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

  describe "get/2 — the file tree" do
    test "lists tracked files, relative to the root", %{dir: dir} do
      model = RepoMap.get(dir)
      assert Map.has_key?(model.files, "lib/foo.ex")
      assert Map.has_key?(model.files, "README.md")
      assert model.file_count == 2
    end

    test "is cached — a second call does not re-walk", %{dir: dir} do
      model1 = RepoMap.get(dir)
      File.write!(Path.join(dir, "lib/new_file.ex"), "defmodule New do\nend\n")
      model2 = RepoMap.get(dir)
      assert model2.built_at == model1.built_at
      refute Map.has_key?(model2.files, "lib/new_file.ex")
    end

    test "refresh: true forces a rewalk", %{dir: dir} do
      _model1 = RepoMap.get(dir)
      File.write!(Path.join(dir, "lib/new_file.ex"), "defmodule New do\nend\n")
      git!(dir, ["add", "."])

      model2 = RepoMap.get(dir, refresh: true)
      assert Map.has_key?(model2.files, "lib/new_file.ex")
    end
  end

  describe "git_state/2 — checkout identity" do
    test "reports the branch and HEAD sha for the workspace root", %{dir: dir} do
      git = RepoMap.git_state(dir)
      assert git.branch == "main"
      assert is_binary(git.head_sha)
    end
  end

  describe "test_status/2" do
    test "is nil until a test run is observed", %{dir: dir} do
      assert RepoMap.test_status(dir) == nil
    end
  end

  describe "symbols_for_file/3" do
    test "computes and caches symbols on first ask, via the shared extractor", %{dir: dir} do
      assert {:ok, symbols} = RepoMap.symbols_for_file(dir, "lib/foo.ex")
      assert {1, "module", "Foo"} in symbols
      assert {2, "function", "bar/1"} in symbols
    end

    test "the second ask is served from cache (same result)", %{dir: dir} do
      assert {:ok, symbols1} = RepoMap.symbols_for_file(dir, "lib/foo.ex")
      assert {:ok, symbols2} = RepoMap.symbols_for_file(dir, "lib/foo.ex")
      assert symbols1 == symbols2
    end

    test "a file not in the tree is a clear error, not a crash", %{dir: dir} do
      assert {:error, msg} = RepoMap.symbols_for_file(dir, "lib/does_not_exist.ex")
      assert msg =~ "not in the repo map"
    end
  end

  describe "observe_tool_result/4 — write tools update the touched file" do
    test "a file_write updates that file's cached symbols without a rewalk", %{dir: dir} do
      model1 = RepoMap.get(dir)

      File.write!(
        Path.join(dir, "lib/foo.ex"),
        "defmodule Foo do\n  def bar(a) do\n    a\n  end\n\n  def baz do\n    :ok\n  end\nend\n"
      )

      :ok = RepoMap.observe_tool_result(dir, "file_write", %{"path" => "lib/foo.ex"}, "ok")

      model2 = RepoMap.get(dir)
      # Same build (no rewalk triggered by the observation)...
      assert model2.built_at == model1.built_at
      # ...but the touched file's symbols are already fresh.
      assert {:ok, symbols} = RepoMap.symbols_for_file(dir, "lib/foo.ex")
      assert {6, "function", "baz/0"} in symbols
    end

    test "observing a tool result before any get/2 call is a safe no-op" do
      dir = Path.join(System.tmp_dir!(), "repo-map-unseen-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert RepoMap.observe_tool_result(dir, "file_write", %{"path" => "x.ex"}, "ok") == :ok
    end
  end

  describe "observe_tool_result/4 — shell tools update test status" do
    test "a mix test run updates test_status", %{dir: dir} do
      _model = RepoMap.get(dir)

      :ok =
        RepoMap.observe_tool_result(
          dir,
          "shell_execute",
          %{"command" => "mix test"},
          "..\n\n2 tests, 0 failures\n"
        )

      status = RepoMap.test_status(dir)
      assert status.status == :passed
      assert status.summary =~ "2 tests, 0 failures"
    end

    test "a non-test shell command does not touch test_status", %{dir: dir} do
      _model = RepoMap.get(dir)
      :ok = RepoMap.observe_tool_result(dir, "shell_execute", %{"command" => "ls -la"}, "a\nb\n")
      assert RepoMap.test_status(dir) == nil
    end
  end

  describe "observe_tool_result/4 — git-mutating shell commands refresh git state" do
    test "a git commit run through shell_execute refreshes the cached git state", %{dir: dir} do
      model1 = RepoMap.get(dir)
      assert model1.git.dirty_count == 0

      File.write!(Path.join(dir, "README.md"), "# changed\n")

      :ok =
        RepoMap.observe_tool_result(
          dir,
          "shell_execute",
          %{"command" => "git add -A && git commit -m wip"},
          "some output"
        )

      # The refresh itself re-runs `git status`, which now (before the
      # observed command's OWN git add/commit actually ran, since this
      # test only feeds the command string) still sees the working tree as
      # it is on disk right now.
      git = RepoMap.git_state(dir)
      assert git.checked_at != model1.git.checked_at
    end
  end

  describe "summary/2" do
    test "is a compact one-liner mentioning file count and the branch", %{dir: dir} do
      line = RepoMap.summary(dir)
      assert line =~ "files tracked"
      assert line =~ "main@"
    end
  end

  describe "cached?/1 — what RepoMap.Watcher gates its poll on" do
    test "is false until get/2 has been called for that root", %{dir: dir} do
      refute RepoMap.cached?(dir)
      _ = RepoMap.get(dir)
      assert RepoMap.cached?(dir)
    end

    test "is false for a root nobody has ever consulted" do
      refute RepoMap.cached?("/definitely/not/consulted")
    end
  end

  describe "sync_from_git/1 — the watcher's poll-tick primitive" do
    test "is a no-op when there is no cached model for the root", %{dir: dir} do
      other = Path.join(dir, "..")

      assert RepoMap.sync_from_git(
               Path.join(other, "never-cached-#{System.unique_integer([:positive])}")
             ) == :ok
    end

    test "refreshes git state without a rewalk, given a cached model", %{dir: dir} do
      model1 = RepoMap.get(dir)
      File.write!(Path.join(dir, "README.md"), "changed\n")

      :ok = RepoMap.sync_from_git(dir)

      model2 = RepoMap.get(dir)
      assert model2.built_at == model1.built_at
      assert model2.git.dirty_count == 1
    end

    test "an externally modified tracked file gets its symbols refreshed", %{dir: dir} do
      _model = RepoMap.get(dir)
      {:ok, before_symbols} = RepoMap.symbols_for_file(dir, "lib/foo.ex")
      assert {2, "function", "bar/1"} in before_symbols

      # Simulate an edit made OUTSIDE OSA (another terminal, an editor) —
      # nothing calls `observe_tool_result/4` for this write.
      File.write!(
        Path.join(dir, "lib/foo.ex"),
        "defmodule Foo do\n  def bar(a) do\n    a\n  end\n\n  def qux do\n    :ok\n  end\nend\n"
      )

      :ok = RepoMap.sync_from_git(dir)

      assert {:ok, after_symbols} = RepoMap.symbols_for_file(dir, "lib/foo.ex")
      assert {6, "function", "qux/0"} in after_symbols
    end

    test "an externally deleted tracked file is dropped from the tree", %{dir: dir} do
      _model = RepoMap.get(dir)
      File.rm!(Path.join(dir, "README.md"))

      :ok = RepoMap.sync_from_git(dir)

      model = RepoMap.get(dir)
      refute Map.has_key?(model.files, "README.md")
    end
  end
end
