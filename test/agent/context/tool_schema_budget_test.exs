defmodule OptimalSystemAgent.Agent.Context.ToolSchemaBudgetTest do
  @moduledoc """
  The tool schemas sent in the request's native `tools` array are part of the
  context window, and the budget did not count them.

  Every consumer of `token_budget/1` — the `/context` meter, the compaction
  trigger, the reported headroom — summed the system prompt, the conversation
  and the response reserve and stopped. Under the `:native_tools` variant the
  schemas live *entirely* in that array (the prose duplicating them is stripped
  from the prompt precisely because the model gets them natively), so the one
  variant that moves the weight out of the prompt also moved it out of the
  accounting. Measured at 15,496 tokens against a 37,172-token reported total:
  the meter read **41.7% low**, and compaction fired later than it believed.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context

  defp budget do
    Context.token_budget(%{
      session_id: "tsb-#{System.unique_integer([:positive])}",
      user_id: nil,
      channel: :cli,
      messages: [%{role: "user", content: "hello"}]
    })
  end

  test "the tool array is reported as its own budget line" do
    b = budget()

    assert Map.has_key?(b, :tool_schema_tokens)
    assert is_integer(b.tool_schema_tokens)

    # Only meaningful with a live registry; a cold VM registers nothing.
    if b.tool_schema_tokens > 0 do
      assert b.tool_schema_tokens > 1_000,
             "37 registered tool schemas cannot cost ~#{b.tool_schema_tokens} tokens"
    end
  end

  test "the total INCLUDES the tool array" do
    b = budget()

    expected =
      b.static_base_tokens + b.dynamic_context_tokens + b.conversation_tokens +
        b.tool_result_tokens + b.response_reserve + b.tool_schema_tokens

    assert b.total_tokens == expected,
           "total must account for every component that is actually sent"
  end

  test "occupied_tokens excludes the response reserve" do
    b = budget()

    assert b.occupied_tokens == b.total_tokens - b.response_reserve
    assert b.occupied_tokens + b.response_reserve == b.total_tokens
  end

  test "headroom and utilization are computed from the corrected total" do
    b = budget()

    assert b.headroom == b.max_tokens - b.total_tokens
    assert_in_delta b.utilization_pct, b.occupied_tokens / b.max_tokens * 100, 0.11
  end

  test "repeated calls agree — the cache cannot drift from the tool set" do
    assert budget().tool_schema_tokens == budget().tool_schema_tokens
  end
end
