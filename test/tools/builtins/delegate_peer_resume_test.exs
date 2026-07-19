defmodule OptimalSystemAgent.Tools.Builtins.DelegatePeerResumeTest do
  @moduledoc """
  P6 — peer-resume (sibling handoff) regression tests: `Delegate.Handler`
  seeds a fresh subagent from a SIBLING's saved transcript (not just the
  parent's live context), and the lineage is tracked as `resumed_from` on the
  `RunStore` run record.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.Delegate.Handler

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_peer_resume_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

      File.rm_rf(tmp)
    end)

    :ok
  end

  # ── Handler.fetch_peer_messages/1 ───────────────────────────────────────

  describe "Handler.fetch_peer_messages/1" do
    test "returns a completed peer's saved transcript, system messages dropped" do
      messages = [
        %{role: "system", content: "you are a debugger"},
        %{role: "user", content: "find the bug"},
        %{role: "assistant", content: "found it: off-by-one in loop.ex:42", tool_calls: []}
      ]

      RunStore.save_messages("agent:p:debugger", messages, %{role: "debugger"})

      peer_messages = Handler.fetch_peer_messages("agent:p:debugger")

      refute Enum.any?(peer_messages, fn m -> m.role == "system" end)
      assert Enum.any?(peer_messages, fn m -> m.content =~ "off-by-one" end)
    end

    test "strips unresolved tool_use pairs (same filter as same-agent resume)" do
      messages = [
        %{role: "user", content: "go"},
        %{role: "assistant", content: "", tool_calls: [%{id: "a", name: "x"}]},
        %{role: "tool", tool_call_id: "a", content: "ok"},
        # Orphan call — never resolved because the debugger was cut off.
        %{role: "assistant", content: "partial", tool_calls: [%{id: "b", name: "y"}]}
      ]

      RunStore.save_messages("agent:p:debugger2", messages, %{role: "debugger"})

      peer_messages = Handler.fetch_peer_messages("agent:p:debugger2")

      refute Enum.any?(peer_messages, fn m -> Map.get(m, :tool_call_id) == "ghost" end)
      # The orphaned call's assistant text survives, its dangling call is dropped.
      assert Enum.any?(peer_messages, fn m -> m.content == "partial" and m.tool_calls == [] end)
    end

    test "returns [] when the peer has no saved transcript (still running / unknown)" do
      assert Handler.fetch_peer_messages("agent:p:no-such-peer") == []
    end

    test "returns [] for a non-string argument instead of raising" do
      assert Handler.fetch_peer_messages(nil) == []
    end
  end

  # ── RunStore: resumed_from lineage tracking ─────────────────────────────

  describe "RunStore resumed_from tracking" do
    test "start_run/1 records resumed_from when provided" do
      RunStore.start_run(%{
        agent_id: "agent:p:fixer",
        parent_session_id: "p",
        role: "fixer",
        task: "fix the bug the debugger found",
        resumed_from: "agent:p:debugger"
      })

      assert %{resumed_from: "agent:p:debugger"} = RunStore.get("agent:p:fixer")
    end

    test "start_run/1 defaults resumed_from to nil for an ordinary spawn" do
      RunStore.start_run(%{agent_id: "agent:p:fresh", parent_session_id: "p", role: "agent"})

      assert %{resumed_from: nil} = RunStore.get("agent:p:fresh")
    end

    test "complete/2 preserves resumed_from set at start_run" do
      RunStore.start_run(%{
        agent_id: "agent:p:fixer2",
        parent_session_id: "p",
        role: "fixer",
        task: "t",
        resumed_from: "agent:p:debugger"
      })

      RunStore.complete("agent:p:fixer2", %{status: :completed, summary: "fixed"})

      assert %{resumed_from: "agent:p:debugger", status: :completed} =
               RunStore.get("agent:p:fixer2")
    end
  end
end
