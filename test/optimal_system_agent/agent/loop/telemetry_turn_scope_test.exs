defmodule OptimalSystemAgent.Agent.Loop.TelemetryTurnScopeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.Telemetry

  defp assistant_call(names) do
    %{role: "assistant", tool_calls: Enum.map(names, &%{name: &1, arguments: "{}"})}
  end

  describe "tools_used_since/2 (per-turn scope)" do
    test "ignores tool calls from earlier turns" do
      earlier = [
        %{role: "user", content: "do work"},
        assistant_call(["shell_execute"]),
        %{role: "assistant", content: "done"}
      ]

      # Trivial follow-up turn: just a user message, no tools ran.
      messages = earlier ++ [%{role: "user", content: "Yeah?"}]

      assert Telemetry.tools_used_since(messages, length(earlier)) == []
    end

    test "counts tool USES, not distinct tool types" do
      prior = [%{role: "user", content: "hi"}]

      turn = [
        assistant_call(["file_read", "file_read", "file_read", "file_read", "file_read"]),
        assistant_call(["shell_execute", "shell_execute", "shell_execute"])
      ]

      names = Telemetry.tools_used_since(prior ++ turn, length(prior))
      assert length(names) == 8
      assert length(Telemetry.substantive_tools(names)) == 8
    end

    test "is safe when compaction shrank the list below the snapshot" do
      assert Telemetry.tools_used_since([%{role: "user", content: "x"}], 5) == []
    end
  end

  describe "internal tool filtering" do
    test "auto-firing bookkeeping tools are not substantive" do
      names = ["memory_save", "memory_recall", "session_search", "recall"]
      assert Telemetry.substantive_tools(names) == []
      assert Enum.all?(names, &Telemetry.internal_tool?/1)
    end

    test "real work stays substantive" do
      refute Telemetry.internal_tool?("shell_execute")
      refute Telemetry.internal_tool?("file_write")
      assert Telemetry.substantive_tools(["memory_save", "shell_execute"]) == ["shell_execute"]
    end
  end

  test "extract_tools_used remains whole-session distinct names" do
    messages = [assistant_call(["a", "a", "b"])]
    assert Telemetry.extract_tools_used(messages) == ["a", "b"]
  end
end
