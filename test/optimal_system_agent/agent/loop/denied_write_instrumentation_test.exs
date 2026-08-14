defmodule OptimalSystemAgent.Agent.Loop.DeniedWriteInstrumentationTest do
  @moduledoc """
  A refused tool call must be REPORTED as a refusal.

  Two instruments were wrong in OSA's favour at once, and together they made a
  benchmark route that was crippled by permission denials read as a clean run:

    1. `handler_hard_deny/1` returned the write handler's raw message
       (`"Access denied: …"`) where every sibling `{:blocked, _}` carries a
       `"Blocked: "` prefix. `finalize_result/5` decides `tool_failed` — and so
       the `success` field on both the `tool_call` end event and the
       `tool_result` event, the `post_tool_use_failure` hook, and the
       grounded-verification evidence ledger — purely from that prefix. A denied
       write was therefore recorded as a SUCCESSFUL tool call.

    2. The `tool_result` event computed `success` a second, different way
       (`!match?({:error, _}, tool_result)`) against a shape that cannot reach
       that point, so it was a constant `true` for EVERY failure.

  And a denial caused by OSA's own scope resolution was attributable to nobody,
  because the `owner` split lives on turn errors and a denial is not one.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.PermissionMode
  alias OptimalSystemAgent.Workspace.Cwd

  setup do
    Cwd.init_session_table()
    sid = "instr-#{System.unique_integer([:positive])}"
    # Overdrive: the headless/bench configuration, and the mode in which a
    # denial is unambiguously the guard talking rather than a missing approval.
    PermissionMode.put(sid, :overdrive)
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")

    prev_write = Application.get_env(:optimal_system_agent, :allowed_write_paths)
    Application.put_env(:optimal_system_agent, :allowed_write_paths, ["/nonexistent-root"])

    on_exit(fn ->
      PermissionMode.clear(sid)

      if prev_write,
        do: Application.put_env(:optimal_system_agent, :allowed_write_paths, prev_write),
        else: Application.delete_env(:optimal_system_agent, :allowed_write_paths)
    end)

    %{session_id: sid}
  end

  defp state(sid) do
    %{
      session_id: sid,
      permission_mode: :overdrive,
      permission_tier: :full,
      messages: [],
      turn_count: 1,
      working_dir: Cwd.get()
    }
  end

  defp collect_events(name) do
    receive do
      {:osa_event, %{type: :tool_call, name: ^name, phase: "end"} = ev} -> {:end_event, ev}
      {:osa_event, _} -> collect_events(name)
    after
      2_000 -> :timeout
    end
  end

  describe "a write denied for being out of the workspace" do
    setup %{session_id: sid} do
      workspace = "/app-instr-#{System.unique_integer([:positive])}"
      Cwd.put_session_dir(sid, workspace)
      Cwd.put_process_override(workspace)
      on_exit(fn -> Cwd.clear_process_override() end)
      %{workspace: workspace}
    end

    test "is reported as a FAILURE, not a success", %{session_id: sid} do
      # A path outside the session workspace AND outside the configured roots.
      tc = %{
        id: "tc-1",
        name: "file_write",
        arguments: %{"path" => "/definitely-not-the-workspace/x.txt", "content" => "x"}
      }

      {_msg, result} = ToolExecutor.execute_tool_call(tc, state(sid))

      # The model-facing text declares the refusal…
      assert String.starts_with?(result, "Blocked:") or String.starts_with?(result, "Error:"),
             "a refusal must be self-declaring, got: #{inspect(String.slice(result, 0, 120))}"

      assert result =~ "Access denied"

      # …and so does the instrument.
      assert {:end_event, ev} = collect_events("file_write")
      refute ev.success, "a denied write must not be reported as a successful tool call"
    end

    test "the denial is attributed to nobody when the path really is foreign", %{session_id: sid} do
      tc = %{
        id: "tc-2",
        name: "file_write",
        arguments: %{"path" => "/definitely-not-the-workspace/x.txt", "content" => "x"}
      }

      ToolExecutor.execute_tool_call(tc, state(sid))

      assert {:end_event, ev} = collect_events("file_write")
      assert Map.get(ev, :fault_owner) == nil
    end

    test "a denial of an IN-workspace path is attributed to OSA", %{
      session_id: sid,
      workspace: ws
    } do
      # The exact regression: the session was told to work in `ws`, and OSA then
      # refused a path inside `ws`. Nothing the model did could avoid that.
      # (The configured roots are pinned away from `ws` in `setup`, and this test
      # deliberately does NOT let the workspace into scope — it forces the
      # disagreement so the attribution can be observed.)
      Cwd.clear_process_override()
      Process.put(:osa_session_id, sid)

      tc = %{
        id: "tc-3",
        name: "file_write",
        arguments: %{"path" => Path.join(ws, "src/main.py"), "content" => "x"}
      }

      # Re-point the scope check at `ws` while leaving the write roots pinned
      # elsewhere, which is precisely the pre-fix disagreement.
      assert :osa ==
               OptimalSystemAgent.Permissions.denial_fault_owner(
                 tc.name,
                 tc.arguments,
                 "Blocked: Access denied: #{tc.arguments["path"]} is outside allowed paths"
               )

      Process.delete(:osa_session_id)
    end
  end

  describe "a successful write" do
    test "is reported as a success with no fault owner", %{session_id: sid} do
      dir = Path.join(System.tmp_dir!(), "osa_instr_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      Application.put_env(:optimal_system_agent, :allowed_write_paths, [dir])

      tc = %{
        id: "tc-4",
        name: "file_write",
        arguments: %{"path" => Path.join(dir, "ok.txt"), "content" => "hello"}
      }

      {_msg, result} = ToolExecutor.execute_tool_call(tc, state(sid))

      refute String.starts_with?(result, "Blocked:")
      refute String.starts_with?(result, "Error:")
      assert File.read!(Path.join(dir, "ok.txt")) == "hello"

      assert {:end_event, ev} = collect_events("file_write")
      assert ev.success
      assert Map.get(ev, :fault_owner) == nil
    end
  end
end
