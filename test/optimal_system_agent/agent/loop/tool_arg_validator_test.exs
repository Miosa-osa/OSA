defmodule OptimalSystemAgent.Agent.Loop.ToolArgValidatorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolArgValidator

  # Unique session id per test so ETS retry counters never collide.
  setup do
    {:ok, session_id: "tav-test-#{System.unique_integer([:positive])}"}
  end

  describe "valid arguments" do
    test "passes through when arguments satisfy the tool schema", %{session_id: sid} do
      tool_call = %{
        name: "file_edit",
        arguments: %{"path" => "/tmp/x.txt", "old_string" => "a", "new_string" => "b"}
      }

      assert {:ok, %{arguments: _}} = ToolArgValidator.validate(tool_call, %{session_id: sid})
    end
  end

  describe "malformed / missing arguments (BUG A)" do
    test "empty args produce a model-facing REASK instead of running with %{}", %{
      session_id: sid
    } do
      tool_call = %{name: "file_edit", arguments: %{}}

      assert {:reask, message} = ToolArgValidator.validate(tool_call, %{session_id: sid})
      assert message =~ "Error:"
      assert message =~ "was invalid"
      assert message =~ "file_edit"
      # Instructor-style: tells the model to rewrite the call.
      assert message =~ "Rewrite"
    end

    test "nil arguments are treated as empty and re-asked", %{session_id: sid} do
      tool_call = %{name: "file_edit", arguments: nil}
      assert {:reask, _message} = ToolArgValidator.validate(tool_call, %{session_id: sid})
    end
  end

  describe "retry cap (N=2)" do
    test "message turns terminal after the retry budget is exhausted", %{session_id: sid} do
      tool_call = %{name: "file_edit", arguments: %{}}
      state = %{session_id: sid}

      # Attempts 1 and 2 offer a correction.
      assert {:reask, m1} = ToolArgValidator.validate(tool_call, state)
      assert m1 =~ "attempt 1 of 2"
      assert {:reask, m2} = ToolArgValidator.validate(tool_call, state)
      assert m2 =~ "attempt 2 of 2"

      # Attempt 3 is terminal — a hard tool error, not another reask, so the
      # loop surfaces it as a failed-tool result instead of re-driving forever.
      assert {:error, m3} = ToolArgValidator.validate(tool_call, state)
      assert m3 =~ "still invalid"
      assert m3 =~ "Stop retrying"
    end

    test "a successful validation resets the retry counter", %{session_id: sid} do
      bad = %{name: "file_edit", arguments: %{}}

      good = %{
        name: "file_edit",
        arguments: %{"path" => "/tmp/x", "old_string" => "a", "new_string" => "b"}
      }

      state = %{session_id: sid}

      assert {:reask, m1} = ToolArgValidator.validate(bad, state)
      assert m1 =~ "attempt 1 of 2"
      # Clean call resets the budget.
      assert {:ok, _} = ToolArgValidator.validate(good, state)
      # Next bad call starts again at attempt 1.
      assert {:reask, m2} = ToolArgValidator.validate(bad, state)
      assert m2 =~ "attempt 1 of 2"
    end
  end

  describe "non-builtin tools" do
    test "unknown / MCP tool names pass through untouched", %{session_id: sid} do
      tool_call = %{name: "mcp_some_unknown_tool", arguments: %{}}
      assert {:ok, %{arguments: _}} = ToolArgValidator.validate(tool_call, %{session_id: sid})
    end
  end
end
