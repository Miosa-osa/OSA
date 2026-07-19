defmodule OptimalSystemAgent.Workspace.CwdTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Workspace.Cwd

  setup do
    # Isolate the per-process override between tests.
    Cwd.clear_process_override()
    on_exit(fn -> Cwd.clear_process_override() end)
    :ok
  end

  describe "original_cwd/set_original_cwd" do
    test "prefers OSA_ORIGINAL_CWD over File.cwd!()" do
      prev = System.get_env("OSA_ORIGINAL_CWD")
      dir = Path.join(System.tmp_dir!(), "osa_cwd_orig_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      System.put_env("OSA_ORIGINAL_CWD", dir)

      on_exit(fn ->
        if prev, do: System.put_env("OSA_ORIGINAL_CWD", prev), else: System.delete_env("OSA_ORIGINAL_CWD")
        File.rm_rf!(dir)
        # Re-capture so later tests/app see a sane value.
        Cwd.set_original_cwd()
      end)

      assert Cwd.set_original_cwd() == Path.expand(dir)
      assert Cwd.original_cwd() == Path.expand(dir)
      # With no process override, get/0 == original_cwd/0.
      assert Cwd.get() == Path.expand(dir)
    end
  end

  describe "process override" do
    test "get/0 returns the process override when set" do
      Cwd.put_process_override("/tmp/osa-project-a")
      assert Cwd.get() == "/tmp/osa-project-a"
      assert Cwd.pwd() == "/tmp/osa-project-a"
    end

    test "with_override/2 scopes the override and restores the prior value" do
      Cwd.put_process_override("/tmp/outer")

      result =
        Cwd.with_override("/tmp/inner", fn ->
          assert Cwd.get() == "/tmp/inner"
          :done
        end)

      assert result == :done
      assert Cwd.get() == "/tmp/outer"
    end

    test "two concurrent processes keep independent cwds (no cross-talk)" do
      parent = self()

      a =
        Task.async(fn ->
          Cwd.put_process_override("/tmp/session-a")
          send(parent, :a_set)
          # Wait until B has also set its override before reading.
          receive do
            :go -> :ok
          after
            1000 -> :ok
          end

          Cwd.get()
        end)

      b =
        Task.async(fn ->
          Cwd.put_process_override("/tmp/session-b")
          Cwd.get()
        end)

      assert_receive :a_set, 1000
      send(a.pid, :go)

      assert Task.await(a) == "/tmp/session-a"
      assert Task.await(b) == "/tmp/session-b"
      # The test process itself was never polluted by either task.
      refute Cwd.get() in ["/tmp/session-a", "/tmp/session-b"]
    end
  end

  describe "identity/project_name" do
    test "home directory renders as ~, not the username" do
      home = System.user_home() || System.get_env("HOME")

      if is_binary(home) and home != "" do
        assert Cwd.project_name(home) == "~"
      end
    end

    test "a plain directory uses its basename" do
      dir = Path.join(System.tmp_dir!(), "osa_myapp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Cwd.project_name(dir) == Path.basename(dir)
    end

    test "identity/1 returns cwd, project_root, name and is_git" do
      dir = Path.join(System.tmp_dir!(), "osa_ident_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      identity = Cwd.identity(dir)
      assert identity.cwd == Path.expand(dir)
      assert is_binary(identity.name)
      assert is_boolean(identity.is_git)
      # Not a git repo → project_root falls back to the dir itself.
      assert identity.project_root == Path.expand(dir)
    end
  end
end
