defmodule OptimalSystemAgent.Tools.Builtins.TaskStopTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.TaskStop
  alias OptimalSystemAgent.Tools.Builtins.TaskStop.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-task-stop"}

  # ── Shim identity ────────────────────────────────────────────────────

  describe "name/0" do
    test "returns task_stop" do
      assert TaskStop.name() == "task_stop"
    end

    test "matches Constants.tool_name/0" do
      assert TaskStop.name() == Constants.tool_name()
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = TaskStop.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "references task_write via safe_ref" do
      assert TaskStop.description() =~ "task_write"
    end

    test "references task_output via safe_ref" do
      assert TaskStop.description() =~ "task_output"
    end
  end

  describe "parameters/0" do
    test "returns valid JSON Schema" do
      params = TaskStop.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "agent_id" in params["required"]
    end
  end

  # ── Loading semantics ────────────────────────────────────────────────

  describe "should_defer?/0" do
    test "returns false" do
      refute TaskStop.should_defer?()
    end
  end

  describe "always_load?/0" do
    test "returns true" do
      assert TaskStop.always_load?()
    end
  end

  # ── Execution semantics ──────────────────────────────────────────────

  describe "concurrency_safe?/2" do
    test "returns false" do
      refute TaskStop.concurrency_safe?(%{"agent_id" => "x"}, @ctx)
    end
  end

  describe "read_only?/2" do
    test "returns false" do
      refute TaskStop.read_only?(%{"agent_id" => "x"}, @ctx)
    end
  end

  describe "destructive?/2" do
    test "returns false" do
      refute TaskStop.destructive?(%{"agent_id" => "x"}, @ctx)
    end
  end

  describe "safety/0" do
    test "returns :write_safe" do
      assert TaskStop.safety() == :write_safe
    end
  end

  # ── Handler: validate ────────────────────────────────────────────────

  describe "Handler.validate/2" do
    test "accepts valid agent_id" do
      assert {:ok, _} = Handler.validate(%{"agent_id" => "some-session"}, @ctx)
    end

    test "rejects non-string agent_id" do
      assert {:error, msg, -32_602} = Handler.validate(%{"agent_id" => 123}, @ctx)
      assert msg =~ "string"
    end

    test "rejects missing agent_id" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, @ctx)
      assert msg =~ "agent_id"
    end
  end

  # ── Handler: check_permissions ───────────────────────────────────────

  describe "Handler.check_permissions/2" do
    test "always allows" do
      assert {:allow, _} = Handler.check_permissions(%{"agent_id" => "x"}, @ctx)
    end
  end

  # ── Handler: execute ─────────────────────────────────────────────────

  describe "Handler.execute/2" do
    test "returns not found message for unknown agent" do
      assert {:ok, msg} = Handler.execute(%{"agent_id" => "nonexistent-agent-xyz"}, @ctx)
      assert msg =~ "not found or already completed"
    end

    test "returns error for missing agent_id" do
      assert {:error, msg} = Handler.execute(%{}, @ctx)
      assert msg =~ "agent_id"
    end
  end

  # ── Shim execute/1 (flat compat) ──────────────────────────────────────

  describe "execute/1" do
    test "returns not found for unknown agent without UseContext" do
      assert {:ok, msg} = TaskStop.execute(%{"agent_id" => "nonexistent-flat"})
      assert msg =~ "not found or already completed"
    end
  end

  # ── UI ────────────────────────────────────────────────────────────────

  describe "UI.render/3" do
    test "tool_use stage" do
      map = UI.render(:tool_use, %{"agent_id" => "abc"}, [])
      assert map.kind == "task_stop"
      assert map.agent_id == "abc"
    end

    test "tool_result stage" do
      map = UI.render(:tool_result, "Agent abc cancelled.", [])
      assert map.kind == "task_stop_result"
      assert map.message == "Agent abc cancelled."
    end

    test "rejected stage" do
      assert %{kind: "task_stop_rejected"} = UI.render(:rejected, nil, [])
    end

    test "error stage" do
      map = UI.render(:error, "boom", [])
      assert map.kind == "task_stop_error"
      assert map.message == "boom"
    end

    test "unknown stage returns nil" do
      assert UI.render(:unknown, nil, []) == nil
    end
  end

  # ── Prompt: safe_ref cross-tool links ────────────────────────────────

  describe "Prompt.render/1" do
    test "renders without error" do
      assert is_binary(Prompt.render([]))
    end

    test "includes task_write reference" do
      assert Prompt.render([]) =~ "task_write"
    end

    test "includes task_output reference" do
      assert Prompt.render([]) =~ "task_output"
    end
  end

  # ── Tool module delegates ─────────────────────────────────────────────

  describe "Tool module" do
    test "name matches shim" do
      assert Tool.name() == TaskStop.name()
    end

    test "execute/2 delegate" do
      assert {:ok, _} = Tool.execute(%{"agent_id" => "no-such-agent"}, @ctx)
    end
  end

  # ── Structured layout (execute/2 present) ────────────────────────────

  describe "structured layout" do
    # Ensure the module is loaded before inspecting exports.
    # function_exported?/3 returns false for unloaded modules even when the
    # .beam file exists — Code.ensure_loaded!/1 is required first.
    setup do
      Code.ensure_loaded!(TaskStop)
      :ok
    end

    test "exports execute/2" do
      assert function_exported?(TaskStop, :execute, 2)
    end

    test "LegacyAdapter detects as structured" do
      assert OptimalSystemAgent.Tools.LegacyAdapter.structured?(TaskStop)
    end
  end
end
