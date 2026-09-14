defmodule OptimalSystemAgent.Agent.Loop.ToolOutputSpillTest do
  @moduledoc """
  Item 9 — the LAST cut before a tool result enters the loop transcript.

  A fat tool result (a pytest dump, a large file_read/bash_output) injected
  whole is re-sent on EVERY later turn, so unbounded results are the biggest
  driver of subagent context runaway. `spill_or_truncate/3` bounds a single
  result: it keeps the head AND the tail, elides the middle to a spilled file,
  is idempotent, and never splits a UTF-8 codepoint.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor

  @tool %{name: "bash_output", id: "call-spill-1"}

  test "an over-cap result keeps BOTH the head and the tail" do
    head = "TOP-OF-OUTPUT-MARKER"
    tail = "BOTTOM-OF-OUTPUT-MARKER"
    big = head <> "\n" <> String.duplicate("x\n", 20_000) <> tail

    out = ToolExecutor.spill_or_truncate(big, 4_000, @tool)

    assert byte_size(out) < byte_size(big), "an over-cap result must shrink"
    assert out =~ head, "the head was lost"
    assert out =~ tail, "the TAIL was lost — where a pass/fail verdict lives"
    assert out =~ "Output truncated"
    # The middle is spilled to a file and cited so the agent can read it on demand.
    assert out =~ "saved at"
    assert out =~ "file_read"
  end

  test "a result within the cap is returned untouched" do
    small = "all good\nnothing to cut"
    assert ToolExecutor.spill_or_truncate(small, 4_000, @tool) == small
  end

  test "it is idempotent — an already-elided result is not re-cut" do
    big = String.duplicate("y\n", 20_000)
    once = ToolExecutor.spill_or_truncate(big, 4_000, @tool)
    twice = ToolExecutor.spill_or_truncate(once, 4_000, @tool)

    assert twice == once,
           "a second pass re-truncated an already-elided result (would drop the tail + reference)"
  end

  test "it never splits a UTF-8 codepoint" do
    # 4-byte emoji: a naive byte cut lands mid-sequence and yields invalid UTF-8,
    # which providers reject outright.
    big = String.duplicate("😀", 10_000)
    out = ToolExecutor.spill_or_truncate(big, 4_000, @tool)

    assert String.valid?(out), "output was not valid UTF-8 after the cut"
    assert byte_size(out) < byte_size(big)
  end

  describe "tool_output_cap/0" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :max_tool_output_bytes)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:optimal_system_agent, :max_tool_output_bytes)
          v -> Application.put_env(:optimal_system_agent, :max_tool_output_bytes, v)
        end
      end)

      :ok
    end

    test "reads the configured knob" do
      Application.put_env(:optimal_system_agent, :max_tool_output_bytes, 12_345)
      assert ToolExecutor.tool_output_cap() == 12_345
    end

    test "falls back to a bounded anti-runaway default when unset" do
      Application.delete_env(:optimal_system_agent, :max_tool_output_bytes)
      cap = ToolExecutor.tool_output_cap()
      assert is_integer(cap) and cap > 0
      assert cap <= 16_384
    end
  end
end
