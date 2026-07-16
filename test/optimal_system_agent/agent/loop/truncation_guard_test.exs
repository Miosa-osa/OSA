defmodule OptimalSystemAgent.Agent.Loop.TruncationGuardTest do
  @moduledoc """
  Tests for the TRUNCATED-MESSAGE tool-call guard in `Agent.Loop.ReactLoop`.

  When a model response is cut off by the token limit, the provider may hand
  back tool-call JSON that happens to parse as valid while its arguments are
  actually partial. Executing it would run a tool with WRONG/partial input.
  The guard (a `handle_result/3` clause) refuses to execute any tool call in a
  truncated message and instead injects failed tool results + a continuation
  directive so the model re-emits complete calls.

  `handle_result/3` is private, so — following the convention in
  `LoopInjectionTest` — the guard's decision predicate and its
  message-construction are mirrored here with the exact same implementation
  and exercised directly.
  """

  use ExUnit.Case, async: true

  # ── Mirror of the guard's match/guard condition ─────────────────────────
  #
  # Real clause head:
  #   defp handle_result(
  #          {:ok, %{tool_calls: tool_calls, stop_reason: stop_reason} = resp}, ...)
  #        when is_list(tool_calls) and tool_calls != [] and
  #               stop_reason in ["max_tokens", "length"]
  defp guard_fires?(%{tool_calls: tool_calls, stop_reason: stop_reason})
       when is_list(tool_calls) and tool_calls != [] and
              stop_reason in ["max_tokens", "length"],
       do: true

  defp guard_fires?(_), do: false

  # ── Mirror of the guard body's message construction ─────────────────────
  defp build_recovery_messages(tool_calls) do
    failed_tool_msgs =
      Enum.map(tool_calls, fn tc ->
        %{
          role: "tool",
          tool_call_id: tc.id,
          content:
            "Error: tool call not executed — the assistant message was truncated by the token " <>
              "limit, so the arguments may be incomplete. Re-issue this call with complete arguments."
        }
      end)

    directive = %{
      role: "system",
      content:
        "[System: Your previous message was truncated by the token limit before the tool call(s) " <>
          "finished. None were executed, because their arguments may be incomplete. Re-emit the " <>
          "complete tool call(s) now.]"
    }

    {failed_tool_msgs, directive}
  end

  defp tc(id), do: %{id: id, name: "file_write", arguments: %{"path" => "/tmp/x"}}

  describe "guard decision predicate" do
    test "fires on Anthropic max_tokens truncation with tool calls" do
      assert guard_fires?(%{tool_calls: [tc("call_1")], stop_reason: "max_tokens"})
    end

    test "fires on OpenAI-compat length truncation with tool calls" do
      assert guard_fires?(%{tool_calls: [tc("call_1")], stop_reason: "length"})
    end

    test "fires when multiple tool calls are present" do
      assert guard_fires?(%{
               tool_calls: [tc("call_1"), tc("call_2")],
               stop_reason: "max_tokens"
             })
    end

    test "does NOT fire when truncated but there are no tool calls" do
      refute guard_fires?(%{tool_calls: [], stop_reason: "max_tokens"})
    end

    test "does NOT fire on a normal (non-truncated) stop reason" do
      refute guard_fires?(%{tool_calls: [tc("call_1")], stop_reason: "end_turn"})
      refute guard_fires?(%{tool_calls: [tc("call_1")], stop_reason: "tool_use"})
      refute guard_fires?(%{tool_calls: [tc("call_1")], stop_reason: "stop"})
    end

    test "does NOT fire when stop_reason is absent (provider did not report one)" do
      refute guard_fires?(%{tool_calls: [tc("call_1")]})
      refute guard_fires?(%{tool_calls: [tc("call_1")], stop_reason: nil})
    end
  end

  describe "recovery message construction" do
    test "emits exactly one failed tool result per tool call, keyed by id" do
      tool_calls = [tc("call_a"), tc("call_b")]
      {failed, _directive} = build_recovery_messages(tool_calls)

      assert length(failed) == 2
      assert Enum.map(failed, & &1.tool_call_id) == ["call_a", "call_b"]
      assert Enum.all?(failed, &(&1.role == "tool"))
    end

    test "each failed tool result explains it was not executed due to truncation" do
      {failed, _} = build_recovery_messages([tc("call_a")])
      [msg] = failed

      assert msg.content =~ "not executed"
      assert msg.content =~ "truncated"
    end

    test "directive is a system message asking the model to re-emit complete calls" do
      {_failed, directive} = build_recovery_messages([tc("call_a")])

      assert directive.role == "system"
      assert directive.content =~ "truncated"
      assert directive.content =~ "Re-emit"
    end
  end
end
