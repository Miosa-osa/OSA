defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktreeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.EnterWorktree.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  @moduletag :tmp_dir

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── validate/2 ────────────────────────────────────────────────────────

  describe "validate/2" do
    test "accepts empty input (all fields optional)", %{ctx: ctx} do
      assert {:ok, %{}} = Handler.validate(%{}, ctx)
    end

    test "accepts valid branch name", %{ctx: ctx} do
      input = %{"branch" => "osa-wt-test-123"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts branch with slashes (feature branches)", %{ctx: ctx} do
      input = %{"branch" => "feature/my-fix"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "rejects blank branch string", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"branch" => "  "}, ctx)
      assert msg =~ "blank"
    end

    test "rejects non-string branch", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"branch" => 42}, ctx)
    end

    test "rejects branch with invalid chars (spaces)", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"branch" => "bad branch name"}, ctx)
      assert msg =~ "invalid characters"
    end

    test "accepts valid explicit path", %{ctx: ctx} do
      input = %{"path" => "/tmp/my-wt"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "rejects blank path string", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"path" => ""}, ctx)
      assert msg =~ "blank"
    end

    test "rejects non-map input", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate("not a map", ctx)
    end
  end

  # ── check_permissions/2 ───────────────────────────────────────────────

  describe "check_permissions/2" do
    test "allows when inside a git repo", %{ctx: ctx} do
      # The project root is a git repo — use it.
      repo_ctx = %{ctx | extras: %{cwd: git_repo_dir()}}
      assert {:allow, _} = Handler.check_permissions(%{}, repo_ctx)
    end

    test "denies when outside a git repo", %{ctx: ctx} do
      tmp = System.tmp_dir!()
      non_git = Path.join(tmp, "osa-test-non-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(non_git)

      on_exit(fn -> File.rm_rf(non_git) end)

      repo_ctx = %{ctx | extras: %{cwd: non_git}}
      assert {:deny, msg} = Handler.check_permissions(%{}, repo_ctx)
      assert msg =~ "git repository"
    end
  end

  # ── execute/2 (happy path) ────────────────────────────────────────────

  describe "execute/2 happy path" do
    @tag :integration
    test "creates a worktree and returns its path", %{ctx: ctx} do
      ts = System.os_time(:second)
      branch = "osa-wt-test-#{ts}"
      tmp_path = Path.join(System.tmp_dir!(), "osa-wt-test-#{ts}")

      repo_ctx = %{ctx | extras: %{cwd: git_repo_dir()}}
      input = %{"branch" => branch, "path" => tmp_path}

      on_exit(fn ->
        System.cmd("git", ["worktree", "remove", "--force", tmp_path],
          cd: git_repo_dir(),
          stderr_to_stdout: true
        )

        System.cmd("git", ["branch", "-D", branch],
          cd: git_repo_dir(),
          stderr_to_stdout: true
        )

        File.rm_rf(tmp_path)
      end)

      assert {:ok, result} = Handler.execute(input, repo_ctx)
      assert result =~ tmp_path
      assert result =~ branch
      assert File.dir?(tmp_path)
    end
  end

  # ── execute/2 (error paths) ───────────────────────────────────────────

  describe "execute/2 error paths" do
    @tag :integration
    test "errors cleanly when worktree path already exists", %{ctx: ctx} do
      existing = System.tmp_dir!()
      repo_ctx = %{ctx | extras: %{cwd: git_repo_dir()}}
      input = %{"path" => existing}

      assert {:error, msg} = Handler.execute(input, repo_ctx)
      assert msg =~ "already exists"
    end

    @tag :integration
    test "errors when branch is already checked out", %{ctx: ctx} do
      # "main" or "master" is already checked out in the main worktree.
      ts = System.os_time(:second)
      tmp_path = Path.join(System.tmp_dir!(), "osa-wt-test-dup-#{ts}")
      repo_ctx = %{ctx | extras: %{cwd: git_repo_dir()}}

      current_branch =
        case System.cmd("git", ["branch", "--show-current"],
               cd: git_repo_dir(),
               stderr_to_stdout: true
             ) do
          {b, 0} -> String.trim(b)
          _ -> "main"
        end

      input = %{"branch" => current_branch, "path" => tmp_path}

      assert {:error, _msg} = Handler.execute(input, repo_ctx)

      File.rm_rf(tmp_path)
    end
  end

  # ── Tool metadata callbacks ───────────────────────────────────────────

  describe "Tool callbacks" do
    test "name, aliases, and deferred status" do
      assert Tool.name() == "enter_worktree"
      assert "worktree_enter" in Tool.aliases()
      assert "worktree_create" in Tool.aliases()
      assert Tool.should_defer?()
      refute Tool.always_load?()
    end

    test "execution semantics" do
      ctx = UseContext.empty()
      refute Tool.read_only?(%{}, ctx)
      refute Tool.destructive?(%{}, ctx)
      refute Tool.concurrency_safe?(%{}, ctx)
      refute Tool.open_world?(%{}, ctx)
      assert Tool.interrupt_behavior() == :block
      assert Tool.safety() == :write_safe
    end

    test "parameters schema has no required fields" do
      params = Tool.parameters()
      assert params["required"] == []
      assert Map.has_key?(params["properties"], "branch")
      assert Map.has_key?(params["properties"], "path")
    end

    test "render/3 returns a map for tool_use" do
      result = Tool.render(:tool_use, %{"branch" => "test-branch"}, [])
      assert is_map(result)
      assert result.kind == "enter_worktree"
    end

    test "render/3 returns nil for unknown stage" do
      assert Tool.render(:unknown_stage, %{}, []) == nil
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp git_repo_dir do
    # Walk up from the test file to find the git root.
    __ENV__.file
    |> Path.dirname()
    |> find_git_root()
  end

  defp find_git_root(dir) do
    if File.exists?(Path.join(dir, ".git")) do
      dir
    else
      parent = Path.dirname(dir)
      if parent == dir, do: File.cwd!(), else: find_git_root(parent)
    end
  end
end
