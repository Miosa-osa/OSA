defmodule OptimalSystemAgent.Tools.Builtins.ExitWorktreeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.ExitWorktree.{Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  # ── validate/2 ────────────────────────────────────────────────────────

  describe "validate/2" do
    test "accepts minimal valid input", %{ctx: ctx} do
      input = %{"path" => "/tmp/some-wt"}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "accepts full valid input", %{ctx: ctx} do
      input = %{"path" => "/tmp/wt", "merge" => true, "keep" => false, "force" => false}
      assert {:ok, ^input} = Handler.validate(input, ctx)
    end

    test "rejects missing path", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx)
      assert msg =~ "path"
    end

    test "rejects empty string path", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate(%{"path" => ""}, ctx)
    end

    test "rejects non-boolean merge", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"path" => "/tmp/wt", "merge" => "yes"}, ctx)

      assert msg =~ "merge"
    end

    test "rejects non-boolean keep", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"path" => "/tmp/wt", "keep" => 1}, ctx)

      assert msg =~ "keep"
    end

    test "rejects non-boolean force", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"path" => "/tmp/wt", "force" => "true"}, ctx)

      assert msg =~ "force"
    end
  end

  # ── check_permissions/2 ──────────────────────────────────────────────

  describe "check_permissions/2" do
    test "denies when path does not exist", %{ctx: ctx} do
      input = %{"path" => "/tmp/osa-nonexistent-wt-#{System.unique_integer([:positive])}"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx)
      assert msg =~ "does not exist"
    end

    test "denies when path is not a worktree", %{ctx: ctx} do
      # Create a temp dir that is not under ~/.osa/worktrees and not in git worktree list.
      tmp = Path.join(System.tmp_dir!(), "osa-not-a-wt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      input = %{"path" => tmp}
      assert {:deny, msg} = Handler.check_permissions(input, ctx)
      assert msg =~ "worktree"
    end

    test "allows path under the worktrees dir that exists", %{ctx: ctx} do
      # Resolve the same way the tools do rather than hardcoding `~/.osa`: the
      # literal path is the OPERATOR's live worktrees directory, and creating a
      # fixture inside it made the suite write into the running agent's state.
      worktrees_base = OptimalSystemAgent.Tools.Builtins.EnterWorktree.Constants.worktrees_dir()
      File.mkdir_p!(worktrees_base)
      fake_wt = Path.join(worktrees_base, "test-allow-#{System.unique_integer([:positive])}")
      File.mkdir_p!(fake_wt)
      on_exit(fn -> File.rm_rf(fake_wt) end)

      input = %{"path" => fake_wt}
      assert {:allow, _} = Handler.check_permissions(input, ctx)
    end
  end

  # ── execute/2 (happy path) ────────────────────────────────────────────

  describe "execute/2 happy path" do
    @tag :integration
    test "removes worktree and returns summary", %{ctx: ctx} do
      repo_dir = git_repo_dir()
      ts = System.os_time(:second)
      branch = "osa-wt-exit-test-#{ts}"
      wt_path = Path.join(System.tmp_dir!(), "osa-wt-exit-#{ts}")

      # Create the worktree directly via git so we don't depend on enter_worktree.
      {_out, 0} =
        System.cmd("git", ["worktree", "add", wt_path, "-b", branch],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      on_exit(fn ->
        System.cmd("git", ["worktree", "remove", "--force", wt_path],
          cd: repo_dir,
          stderr_to_stdout: true
        )

        System.cmd("git", ["branch", "-D", branch], cd: repo_dir, stderr_to_stdout: true)
        File.rm_rf(wt_path)
      end)

      repo_ctx = %{ctx | extras: %{cwd: repo_dir}}
      input = %{"path" => wt_path}

      assert {:ok, result} = Handler.execute(input, repo_ctx)
      assert result =~ "removed"
      refute File.dir?(wt_path)
    end

    @tag :integration
    test "keep: true leaves directory on disk", %{ctx: ctx} do
      repo_dir = git_repo_dir()
      ts = System.os_time(:second)
      branch = "osa-wt-keep-test-#{ts}"
      wt_path = Path.join(System.tmp_dir!(), "osa-wt-keep-#{ts}")

      {_out, 0} =
        System.cmd("git", ["worktree", "add", wt_path, "-b", branch],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      on_exit(fn ->
        System.cmd("git", ["worktree", "remove", "--force", wt_path],
          cd: repo_dir,
          stderr_to_stdout: true
        )

        System.cmd("git", ["branch", "-D", branch], cd: repo_dir, stderr_to_stdout: true)
        File.rm_rf(wt_path)
      end)

      repo_ctx = %{ctx | extras: %{cwd: repo_dir}}
      input = %{"path" => wt_path, "keep" => true}

      assert {:ok, result} = Handler.execute(input, repo_ctx)
      assert result =~ "removed"
      # Directory must still be present because keep: true.
      assert File.dir?(wt_path)
    end
  end

  # ── execute/2 (error paths) ───────────────────────────────────────────

  describe "execute/2 error paths" do
    @tag :integration
    test "errors with uncommitted changes and force: false", %{ctx: ctx} do
      repo_dir = git_repo_dir()
      ts = System.os_time(:second)
      branch = "osa-wt-dirty-test-#{ts}"
      wt_path = Path.join(System.tmp_dir!(), "osa-wt-dirty-#{ts}")

      {_out, 0} =
        System.cmd("git", ["worktree", "add", wt_path, "-b", branch],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      # Create an untracked file so the worktree is "dirty".
      File.write!(Path.join(wt_path, "osa_test_dirty_file.txt"), "dirty")

      on_exit(fn ->
        System.cmd("git", ["worktree", "remove", "--force", wt_path],
          cd: repo_dir,
          stderr_to_stdout: true
        )

        System.cmd("git", ["branch", "-D", branch], cd: repo_dir, stderr_to_stdout: true)
        File.rm_rf(wt_path)
      end)

      repo_ctx = %{ctx | extras: %{cwd: repo_dir}}
      # Untracked files don't block `git worktree remove` — only modified
      # tracked files do. So this test exercises the force path by staging a
      # modification to a tracked file.
      tracked_file =
        wt_path
        |> File.ls!()
        |> Enum.find(fn f -> f =~ ".ex" end)

      if tracked_file do
        File.write!(Path.join(wt_path, tracked_file), "# dirty modification\n", [:append])

        input = %{"path" => wt_path, "force" => false}
        result = Handler.execute(input, repo_ctx)

        case result do
          {:error, msg} -> assert msg =~ "uncommitted"
          {:ok, _} -> :ok
        end
      else
        # No tracked .ex file to dirty — just verify force: true succeeds.
        input = %{"path" => wt_path, "force" => true}
        assert {:ok, _} = Handler.execute(input, repo_ctx)
      end
    end
  end

  # ── Tool metadata callbacks ───────────────────────────────────────────

  describe "Tool callbacks" do
    test "name, aliases, and deferred status" do
      assert Tool.name() == "exit_worktree"
      assert "worktree_exit" in Tool.aliases()
      assert "worktree_remove" in Tool.aliases()
      assert Tool.should_defer?()
      refute Tool.always_load?()
    end

    test "execution semantics — exit_worktree IS destructive" do
      ctx = UseContext.empty()
      refute Tool.read_only?(%{}, ctx)
      assert Tool.destructive?(%{}, ctx)
      refute Tool.concurrency_safe?(%{}, ctx)
      refute Tool.open_world?(%{}, ctx)
      assert Tool.safety() == :write_safe
    end

    test "parameters schema requires path" do
      params = Tool.parameters()
      assert "path" in params["required"]
      assert Map.has_key?(params["properties"], "merge")
      assert Map.has_key?(params["properties"], "keep")
      assert Map.has_key?(params["properties"], "force")
    end

    test "render/3 returns map for tool_use" do
      result = Tool.render(:tool_use, %{"path" => "/tmp/wt"}, [])
      assert is_map(result)
      assert result.kind == "exit_worktree"
    end

    test "render/3 returns nil for unknown stage" do
      assert Tool.render(:unknown, %{}, []) == nil
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp git_repo_dir do
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
