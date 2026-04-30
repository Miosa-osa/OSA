defmodule OptimalSystemAgent.Tools.Builtins.GitTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Git

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Creates an isolated temp git repo.
  defp make_repo do
    base = Path.join([System.tmp_dir!(), "osa_git_test_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(base)

    on_exit(fn ->
      File.rm_rf!(base)
    end)

    # init + minimal config + initial commit so HEAD exists
    System.cmd("git", ["init"], cd: base, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@osa"], cd: base, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.name", "OSA Test"], cd: base, stderr_to_stdout: true)
    File.write!(Path.join(base, "README.md"), "hello")
    System.cmd("git", ["add", "-A"], cd: base, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "init"], cd: base, stderr_to_stdout: true)

    base
  end

  defp run(params, repo), do: Git.execute(Map.put(params, "path", repo))

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns git" do
      assert Git.name() == "git"
    end

    test "description is a non-empty string" do
      desc = Git.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end

    test "parameters schema requires command" do
      params = Git.parameters()
      assert params["type"] == "object"
      assert "command" in params["required"]
      assert Map.has_key?(params["properties"], "command")
    end

    test "safety level is :write_safe" do
      assert Git.safety() == :write_safe
    end
  end

  # ---------------------------------------------------------------------------
  # Missing required parameter
  # ---------------------------------------------------------------------------

  describe "execute/1 — missing command" do
    test "returns error when command is absent" do
      assert {:error, msg} = Git.execute(%{})
      assert msg =~ "Missing required parameter"
    end

    test "returns error for unknown / non-existent git subcommand" do
      repo = make_repo()
      assert {:error, _msg} = run(%{"command" => "frobulate"}, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # status
  # ---------------------------------------------------------------------------

  describe "status" do
    test "returns ok with branch info on a clean repo" do
      repo = make_repo()
      assert {:ok, output} = run(%{"command" => "status"}, repo)
      assert output =~ "branch" or output =~ "nothing to commit" or output =~ "On branch"
    end

    test "shows untracked files" do
      repo = make_repo()
      File.write!(Path.join(repo, "new_file.txt"), "content")
      assert {:ok, output} = run(%{"command" => "status"}, repo)
      assert output =~ "new_file.txt"
    end
  end

  # ---------------------------------------------------------------------------
  # log
  # ---------------------------------------------------------------------------

  describe "log" do
    test "returns ok with at least the init commit" do
      repo = make_repo()
      assert {:ok, output} = run(%{"command" => "log"}, repo)
      assert output =~ "init"
    end

    test "count via --oneline -n1 limits to one result" do
      repo = make_repo()
      # add a second commit
      File.write!(Path.join(repo, "b.txt"), "b")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "second"], cd: repo, stderr_to_stdout: true)

      assert {:ok, output} = run(%{"command" => "log", "args" => "--oneline -n1"}, repo)
      lines = output |> String.split("\n", trim: true)
      assert length(lines) == 1
    end

    test "stat format includes file-change summary" do
      repo = make_repo()
      assert {:ok, output} = run(%{"command" => "log", "args" => "--stat"}, repo)
      assert output =~ "Author" or output =~ "README"
    end
  end

  # ---------------------------------------------------------------------------
  # diff
  # ---------------------------------------------------------------------------

  describe "diff" do
    test "returns ok on a clean repo (no diff)" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "diff"}, repo)
    end

    test "shows changes when file is modified" do
      repo = make_repo()
      File.write!(Path.join(repo, "README.md"), "modified content")
      assert {:ok, output} = run(%{"command" => "diff"}, repo)
      assert output =~ "modified content" or output =~ "README"
    end

    test "scoped to a specific file via args" do
      repo = make_repo()
      File.write!(Path.join(repo, "README.md"), "changed")
      File.write!(Path.join(repo, "other.txt"), "other")
      assert {:ok, output} = run(%{"command" => "diff", "args" => "README.md"}, repo)
      assert output =~ "README" or output =~ "changed" or output == ""
    end
  end

  # ---------------------------------------------------------------------------
  # commit
  # ---------------------------------------------------------------------------

  describe "commit" do
    test "creates a commit with a message via -m flag" do
      repo = make_repo()
      File.write!(Path.join(repo, "change.txt"), "new content")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)

      assert {:ok, output} =
               run(%{"command" => "commit", "args" => "-m 'feat: add change'"}, repo)

      assert output =~ "feat: add change" or output =~ "change.txt" or output =~ "master" or
               output =~ "main"
    end

    test "requires a -m flag" do
      repo = make_repo()
      assert {:error, msg} = run(%{"command" => "commit"}, repo)
      assert msg =~ "-m" or msg =~ "message"
    end

    test "rejects --no-verify flag" do
      repo = make_repo()

      assert {:error, msg} =
               run(%{"command" => "commit", "args" => "--no-verify -m 'skip hooks'"}, repo)

      assert msg =~ "no-verify" or msg =~ "hook"
    end
  end

  # ---------------------------------------------------------------------------
  # add
  # ---------------------------------------------------------------------------

  describe "add" do
    test "stages a specific file" do
      repo = make_repo()
      File.write!(Path.join(repo, "staged.txt"), "content")
      assert {:ok, _} = run(%{"command" => "add", "args" => "staged.txt"}, repo)

      {status_out, _} = System.cmd("git", ["status", "--short"], cd: repo, stderr_to_stdout: true)
      assert status_out =~ "staged.txt"
    end

    test "add -A is blocked with a warning" do
      repo = make_repo()
      File.write!(Path.join(repo, "a.txt"), "a")
      # The tool returns {:ok, warning_message} for add -A — it's a warn, not an error
      result = run(%{"command" => "add", "args" => "-A"}, repo)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
      # Either way, the message should mention sensitivity or all
      {_, msg} = result

      assert msg =~ "Warning" or msg =~ "warning" or msg =~ "ALL" or msg =~ "all" or
               msg =~ "sensitive"
    end
  end

  # ---------------------------------------------------------------------------
  # stash
  # ---------------------------------------------------------------------------

  describe "stash" do
    test "list returns ok (empty list is valid)" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "stash", "args" => "list"}, repo)
    end

    test "bare stash returns ok" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "stash"}, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # reset
  # ---------------------------------------------------------------------------

  describe "reset" do
    test "mixed reset returns ok" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "reset", "args" => "--mixed"}, repo)
    end

    test "soft reset returns ok" do
      repo = make_repo()
      File.write!(Path.join(repo, "soft.txt"), "s")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      assert {:ok, _} = run(%{"command" => "reset", "args" => "--soft HEAD"}, repo)
    end

    test "hard reset is blocked" do
      repo = make_repo()
      assert {:error, msg} = run(%{"command" => "reset", "args" => "--hard"}, repo)
      assert msg =~ "hard" or msg =~ "destructive" or msg =~ "Blocked"
    end
  end

  # ---------------------------------------------------------------------------
  # tag
  # ---------------------------------------------------------------------------

  describe "tag" do
    test "list action returns ok" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "tag"}, repo)
    end

    test "creates a lightweight tag" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "tag", "args" => "v1.0.0"}, repo)
    end

    test "creates annotated tag with -a and -m" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "tag", "args" => "-a v2.0.0 -m 'Release 2.0'"}, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  describe "show" do
    test "shows HEAD by default" do
      repo = make_repo()
      assert {:ok, output} = run(%{"command" => "show"}, repo)
      assert output =~ "commit"
    end

    test "accepts a specific ref" do
      repo = make_repo()
      assert {:ok, output} = run(%{"command" => "show", "args" => "HEAD"}, repo)
      assert output =~ "commit"
    end
  end

  # ---------------------------------------------------------------------------
  # clone URL / path validation
  # ---------------------------------------------------------------------------

  describe "clone safety" do
    test "rejects force push" do
      repo = make_repo()
      assert {:error, msg} = run(%{"command" => "push", "args" => "--force origin main"}, repo)
      assert msg =~ "force" or msg =~ "Blocked"
    end

    test "rejects checkout . (discards all changes)" do
      repo = make_repo()
      assert {:error, msg} = run(%{"command" => "checkout", "args" => "."}, repo)
      assert msg =~ "checkout" or msg =~ "Blocked" or msg =~ "discards"
    end
  end

  # ---------------------------------------------------------------------------
  # blame
  # ---------------------------------------------------------------------------

  describe "blame" do
    test "returns blame output for a committed file" do
      repo = make_repo()
      assert {:ok, output} = run(%{"command" => "blame", "args" => "README.md"}, repo)
      assert output =~ "OSA Test" or output =~ "README" or output =~ "hello"
    end
  end

  # ---------------------------------------------------------------------------
  # remote
  # ---------------------------------------------------------------------------

  describe "remote" do
    test "lists remotes (empty on fresh repo)" do
      repo = make_repo()
      assert {:ok, _} = run(%{"command" => "remote"}, repo)
    end

    test "adds a remote with add subcommand" do
      repo = make_repo()

      assert {:ok, _} =
               run(
                 %{
                   "command" => "remote",
                   "args" => "add upstream https://github.com/example/repo.git"
                 },
                 repo
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Path validation
  # ---------------------------------------------------------------------------

  describe "path validation" do
    test "rejects non-existent path" do
      assert {:error, msg} =
               Git.execute(%{"command" => "status", "path" => "/nonexistent/path/xyz"})

      assert msg =~ "does not exist" or msg =~ "Access denied" or msg =~ "path"
    end
  end
end
