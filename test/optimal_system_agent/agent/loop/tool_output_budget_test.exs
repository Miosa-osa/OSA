defmodule OptimalSystemAgent.Agent.Loop.ToolOutputBudgetTest do
  @moduledoc """
  Tool output is the dominant consumer of the context window.

  Measured live: a working session sat at 370.5k input tokens against a 1M
  window — a real 37% spent before the model reasoned about any of it. At the
  old 50 KB budget a single tool result could carry ~12.8k tokens, so twenty
  tool calls could account for ~256k tokens of that on their own.

  The context window itself was never misconfigured: every Claude 5 model
  resolves to 1_000_000 and the meter's arithmetic was correct. The tokens were
  real, which is why the fix is in what gets sent rather than in how it is
  counted.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage

  @budget Application.compile_env(:optimal_system_agent, :max_tool_output_bytes, 16_384)

  test "the configured budget is small enough to matter" do
    # 50 KB is ~12.8k tokens per result. Anything at or above that reintroduces
    # the problem this test exists for.
    assert @budget <= 16_384,
           "tool output budget of #{@budget} bytes is large enough to dominate the window"
  end

  test "an over-budget result keeps BOTH ends, not just the head" do
    # Head-only truncation drops the end of a build or test run — the part that
    # says whether it passed, which is usually why the tool was called.
    head = "TOP-OF-OUTPUT-MARKER"
    tail = "BOTTOM-OF-OUTPUT-MARKER"
    filler = String.duplicate("x", @budget * 3)
    big = "#{head}\n#{filler}\n#{tail}"

    out = ToolResultStorage.apply_budget(big, "shell_execute", "call-1", "sess-budget")

    assert byte_size(out) < byte_size(big), "an over-budget result must be reduced"
    assert out =~ head, "the head of the output was lost"
    assert out =~ tail, "the TAIL was lost — where a pass/fail verdict lives"
  end

  test "a result inside the budget is returned untouched" do
    small = "all good\nnothing to truncate"
    assert ToolResultStorage.apply_budget(small, "shell_execute", "call-2", "sess-budget") ==
             small
  end

  test "the reduced result is a small fraction of a large one" do
    big = String.duplicate("line of build output\n", 20_000)
    out = ToolResultStorage.apply_budget(big, "shell_execute", "call-3", "sess-budget")

    assert byte_size(out) < div(byte_size(big), 4),
           "reduction was #{byte_size(out)} from #{byte_size(big)} — not enough to change the bill"
  end
end
