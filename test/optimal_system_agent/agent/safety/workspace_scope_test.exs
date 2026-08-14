defmodule OptimalSystemAgent.Agent.Safety.WorkspaceScopeTest do
  @moduledoc """
  The session's declared `working_dir` is authoritative for permission scope.

  ## What these tests are guarding

  `PathPolicy`'s allowed roots were a static, node-wide allowlist defaulting to
  `["~", "/tmp"]`. On a developer machine the project lives under `$HOME`, so
  every path in the workspace passed — for the wrong reason. In a container
  (`HOME=/root`, workspace `/app`) nothing in the workspace passed at all and
  the agent was told `Access denied: /app/… is outside allowed paths` for the
  files it had been given the job of editing.

  Every test below therefore constructs a workspace that is NOT under `$HOME`
  and NOT under the OS process cwd — the runtime shape a unit test running from
  the repo root does not otherwise have, which is exactly why this survived a
  green suite.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Safety.PathPolicy
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Workspace.Cwd

  # A workspace outside $HOME and outside /tmp — i.e. outside every configured
  # root — standing in for the container's /app.
  setup do
    Cwd.init_session_table()

    prev_read = Application.get_env(:optimal_system_agent, :allowed_read_paths)
    prev_write = Application.get_env(:optimal_system_agent, :allowed_write_paths)
    prev_override = Process.get(:osa_cwd_override)
    prev_sid = Process.get(:osa_session_id)

    # Pin the configured roots so the test does not depend on the developer's
    # $HOME happening to contain the repo.
    Application.put_env(:optimal_system_agent, :allowed_read_paths, ["/nonexistent-root"])
    Application.put_env(:optimal_system_agent, :allowed_write_paths, ["/nonexistent-root"])

    workspace = "/app-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      restore = fn
        key, nil -> Application.delete_env(:optimal_system_agent, key)
        key, value -> Application.put_env(:optimal_system_agent, key, value)
      end

      restore.(:allowed_read_paths, prev_read)
      restore.(:allowed_write_paths, prev_write)

      if prev_override, do: Process.put(:osa_cwd_override, prev_override)
      if is_nil(prev_override), do: Process.delete(:osa_cwd_override)
      if prev_sid, do: Process.put(:osa_session_id, prev_sid)
      if is_nil(prev_sid), do: Process.delete(:osa_session_id)
    end)

    %{workspace: workspace}
  end

  describe "a session whose working_dir differs from the OS cwd" do
    test "the workspace is writable via the per-process override", %{workspace: ws} do
      Cwd.put_process_override(ws)

      assert :ok == PathPolicy.check_write(Path.join(ws, "src/main.py"))
      assert :ok == PathPolicy.check_read(Path.join(ws, "src/main.py"))
      assert Permissions.path_in_scope?(Path.join(ws, "src/main.py"))
    end

    test "…and the workspace root itself is a root", %{workspace: ws} do
      Cwd.put_process_override(ws)
      assert (ws <> "/") in PathPolicy.write_roots()
      assert (ws <> "/") in PathPolicy.read_roots()
    end

    test "a directory added with /add-dir is in scope too", %{workspace: ws} do
      Cwd.put_process_override(ws)
      extra = "/extra-#{System.unique_integer([:positive])}"

      Permissions.add_directory(extra)

      assert :ok == PathPolicy.check_write(Path.join(extra, "out.txt"))
      assert Permissions.path_in_scope?(Path.join(extra, "out.txt"))
    end
  end

  describe "headless / no interactive session — no process-dictionary override" do
    # The process dictionary does not cross a spawned Task. This is the path
    # that must hold when nothing copied the override: the session's working_dir
    # is recorded against the SESSION, and any process that knows which session
    # it is acting for resolves it.
    test "the session's recorded working_dir is authoritative", %{workspace: ws} do
      sid = "sess-#{System.unique_integer([:positive])}"
      Cwd.clear_process_override()
      Cwd.put_session_dir(sid, ws)
      Process.put(:osa_session_id, sid)

      assert Cwd.get() == ws
      assert :ok == PathPolicy.check_write(Path.join(ws, "answer.txt"))
      assert Permissions.path_in_scope?(Path.join(ws, "answer.txt"))
    end

    test "it survives an actual Task boundary the way the tool executor crosses it", %{
      workspace: ws
    } do
      sid = "sess-#{System.unique_integer([:positive])}"
      Cwd.put_session_dir(sid, ws)

      # No override, no session id inside the Task other than the one the
      # executor republishes — exactly ToolOrchestrator's boundary.
      task =
        Task.async(fn ->
          Process.put(:osa_session_id, sid)
          {Cwd.get(), PathPolicy.check_write(Path.join(ws, "x.txt"))}
        end)

      assert {^ws, :ok} = Task.await(task)
    end

    test "a process with NO session falls back to the boot dir, not to the workspace", %{
      workspace: ws
    } do
      Cwd.clear_process_override()
      Process.delete(:osa_session_id)

      refute Cwd.get() == ws
      assert {:deny, _} = PathPolicy.check_write(Path.join(ws, "x.txt"))
    end
  end

  describe "the boundary is not weakened" do
    test "a path outside the workspace is still denied", %{workspace: ws} do
      Cwd.put_process_override(ws)

      assert {:deny, reason} = PathPolicy.check_write("/somewhere-else/x.txt")
      assert reason =~ "outside allowed paths"
      refute Permissions.path_in_scope?("/somewhere-else/x.txt")
      assert {:deny, _} = PathPolicy.check_read("/somewhere-else/x.txt")
    end

    test "a sibling directory sharing the workspace's prefix is denied", %{workspace: ws} do
      Cwd.put_process_override(ws)
      # `/app-1-evil` must not match the root `/app-1`.
      assert {:deny, _} = PathPolicy.check_write(ws <> "-evil/x.txt")
    end

    test "protected locations stay blocked even when they ARE the workspace" do
      # blocked_write? is evaluated before the roots check, so declaring a
      # workspace under /etc cannot unblock /etc.
      Cwd.put_process_override("/etc")
      assert {:deny, reason} = PathPolicy.check_write("/etc/passwd")
      assert reason =~ "protected location"
    end

    test "credential stores stay sensitive inside the workspace", %{workspace: ws} do
      Cwd.put_process_override(ws)
      assert {:deny, reason} = PathPolicy.check_read(Path.join(ws, ".aws/credentials"))
      assert reason =~ "sensitive file"
    end
  end

  describe "fault attribution for refusals" do
    test "a scope denial of an IN-workspace path is OSA's fault", %{workspace: ws} do
      Cwd.put_process_override(ws)
      path = Path.join(ws, "src/main.py")

      assert :osa ==
               Permissions.denial_fault_owner(
                 "file_write",
                 %{"path" => path},
                 "Error: Permission denied: Access denied: #{path} is outside allowed paths"
               )
    end

    test "a scope denial of a genuinely foreign path is NOT OSA's fault", %{workspace: ws} do
      Cwd.put_process_override(ws)

      assert nil ==
               Permissions.denial_fault_owner(
                 "file_write",
                 %{"path" => "/somewhere-else/x.txt"},
                 "Error: Access denied: /somewhere-else/x.txt is outside allowed paths"
               )
    end

    test "a non-scope failure is not attributed at all", %{workspace: ws} do
      Cwd.put_process_override(ws)

      assert nil ==
               Permissions.denial_fault_owner(
                 "file_edit",
                 %{"path" => Path.join(ws, "a.ex")},
                 "Error: old_string not found in file"
               )
    end

    test "a multi_file_edit batch is attributed on all of its targets", %{workspace: ws} do
      Cwd.put_process_override(ws)
      inside = Path.join(ws, "a.ex")

      assert :osa ==
               Permissions.denial_fault_owner(
                 "multi_file_edit",
                 %{"edits" => [%{"path" => inside}]},
                 "Error: Access denied: #{inside} is outside allowed paths"
               )

      # One foreign target in the batch means the refusal was legitimate.
      assert nil ==
               Permissions.denial_fault_owner(
                 "multi_file_edit",
                 %{"edits" => [%{"path" => inside}, %{"path" => "/elsewhere/b.ex"}]},
                 "Error: Access denied: /elsewhere/b.ex is outside allowed paths"
               )
    end
  end
end
