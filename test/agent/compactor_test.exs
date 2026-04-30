defmodule OptimalSystemAgent.Agent.CompactorTest do
  @moduledoc """
  Unit tests for the intelligent sliding-window context compactor.

  Tests target the pure-Elixir logic accessible via the public API:
    - estimate_tokens/1        (message list and string overloads)
    - utilization/1            (percentage calculation)
    - maybe_compact/1          (pipeline entry point — LLM disabled in test env)
    - stats/0                  (GenServer metrics)

  The test config sets `compactor_llm_enabled: false`, so pipeline steps 3
  (summarize_warm) and 4 (compress_cold) return stub responses without making
  real LLM calls.  Steps 1, 2, and 5 are pure Elixir and fully exercised.

  Zone boundaries used in tests mirror the module attributes:
    @hot_zone_size  20
    @warm_zone_end  50
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp msg(role, content, extra \\ %{}) do
    Map.merge(%{role: role, content: content}, extra)
  end

  defp user(content), do: msg("user", content)
  defp asst(content), do: msg("assistant", content)

  # Build N user+assistant message pairs (2N messages total)
  defp build_conversation(n, word_count \\ 10) do
    words = String.duplicate("word ", word_count)

    Enum.flat_map(1..n, fn i ->
      [user("User turn #{i}: #{words}"), asst("Asst turn #{i}: #{words}")]
    end)
  end

  # ---------------------------------------------------------------------------
  # estimate_tokens/1 — string overload
  # ---------------------------------------------------------------------------

  describe "estimate_tokens/1 — string" do
    test "returns 0 for nil" do
      assert Compactor.estimate_tokens(nil) == 0
    end

    test "returns 0 for empty string" do
      assert Compactor.estimate_tokens("") == 0
    end

    test "returns positive integer for non-empty text" do
      count = Compactor.estimate_tokens("hello world")
      assert is_integer(count)
      assert count > 0
    end

    test "longer text produces higher estimate" do
      short = Compactor.estimate_tokens("hi there")
      long = Compactor.estimate_tokens(String.duplicate("hello world ", 500))
      assert long > short
    end

    test "punctuation-heavy text counts more than equivalent word-only text" do
      plain = Compactor.estimate_tokens("hello world foo bar baz")
      punct = Compactor.estimate_tokens("hello, world; foo: bar. baz!")
      # Punctuation adds 0.5 each to the heuristic
      assert punct >= plain
    end
  end

  # ---------------------------------------------------------------------------
  # estimate_tokens/1 — message list overload
  # ---------------------------------------------------------------------------

  describe "estimate_tokens/1 — message list" do
    test "returns 0 for empty list" do
      assert Compactor.estimate_tokens([]) == 0
    end

    test "counts tokens for a single plain message" do
      count = Compactor.estimate_tokens([user("hello world")])
      assert count > 0
    end

    test "accumulates over multiple messages" do
      one = Compactor.estimate_tokens([user("hello world")])
      two = Compactor.estimate_tokens([user("hello world"), asst("hello world")])
      assert two > one
    end

    test "adds overhead for tool_calls in a message" do
      plain_msg = asst("normal response")

      tool_msg = %{
        role: "assistant",
        content: "",
        tool_calls: [%{name: "file_read", arguments: "{\"path\":\"/tmp/x\"}"}]
      }

      plain_tokens = Compactor.estimate_tokens([plain_msg])
      tool_tokens = Compactor.estimate_tokens([tool_msg])
      assert tool_tokens > plain_tokens
    end

    test "handles messages with nil content gracefully" do
      count = Compactor.estimate_tokens([%{role: "user", content: nil}])
      assert is_integer(count)
      assert count >= 0
    end

    test "adds 4-token per-message overhead (framing cost)" do
      # A message with zero-token content should still contribute 4 tokens
      empty_msg_tokens = Compactor.estimate_tokens([%{role: "user", content: ""}])
      assert empty_msg_tokens == 4
    end
  end

  # ---------------------------------------------------------------------------
  # utilization/1
  # ---------------------------------------------------------------------------

  describe "utilization/1" do
    test "returns 0.0 for empty message list" do
      assert Compactor.utilization([]) == 0.0
    end

    test "returns a float between 0 and 100" do
      messages = build_conversation(5)
      util = Compactor.utilization(messages)
      assert is_float(util)
      assert util >= 0.0
      assert util <= 100.0
    end

    test "larger conversation produces higher utilization" do
      small = Compactor.utilization(build_conversation(2))
      large = Compactor.utilization(build_conversation(20))
      assert large > small
    end

    test "result is rounded to 1 decimal place" do
      messages = build_conversation(5)
      util = Compactor.utilization(messages)
      # Float.round/2 to 1dp — check it's not excessively precise
      assert util == Float.round(util, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_compact/1 — below threshold (no compaction)
  # ---------------------------------------------------------------------------

  describe "maybe_compact/1 — below threshold" do
    test "returns messages unchanged when utilization is low" do
      # A tiny conversation is well below any threshold
      messages = build_conversation(3)
      result = Compactor.maybe_compact(messages)
      assert result == messages
    end

    test "returns messages unchanged for empty list" do
      assert Compactor.maybe_compact([]) == []
    end

    test "never raises — safe even with malformed messages" do
      bad_messages = [
        %{role: nil, content: nil},
        %{unexpected: :key},
        "not_a_map"
      ]

      # Should not raise — maybe_compact/1 is designed to be safe
      result = Compactor.maybe_compact(bad_messages)
      assert is_list(result)
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_compact/1 — pipeline steps (using test-env LLM stub)
  # ---------------------------------------------------------------------------

  describe "maybe_compact/1 — strip_tool_args pipeline step" do
    test "returns a list when pipeline is triggered above threshold" do
      # Force above threshold by setting a tiny max_context_tokens temporarily.
      # The exact step reached depends on conversation size and token counts,
      # but the result must always be a valid message list.
      Application.put_env(:optimal_system_agent, :max_context_tokens, 100)
      Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)

      tool_msg = %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{
            name: "shell_execute",
            arguments: "very long argument string with lots of content here"
          }
        ]
      }

      messages = [tool_msg, user("follow up"), asst("response")]
      result = Compactor.maybe_compact(messages)

      assert is_list(result)
      assert length(result) > 0
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
      Application.delete_env(:optimal_system_agent, :compaction_warn)
    end

    test "strip_tool_args replaces argument content with placeholder" do
      # Set max_context_tokens small enough that the conversation (with long tool args)
      # exceeds the 60% aggressive target, but large enough that emergency (>tier3)
      # never fires.  This isolates step 1 as the satisfying step.
      #
      # Sizing: long_args ~260 tokens, 5 pairs * 20 words ~= 200 tokens, overhead ~55
      # → total ~515 tokens.  With max=800, target=0.6*800=480.  515>480 → step 1 fires.
      # After stripping args: ~255 tokens < 480 → pipeline stops at step 1.
      Application.put_env(:optimal_system_agent, :max_context_tokens, 800)
      Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)
      Application.put_env(:optimal_system_agent, :compaction_aggressive, 0.0)
      Application.put_env(:optimal_system_agent, :compaction_emergency, 1.1)

      long_args = String.duplicate("argument data ", 200)

      tool_msg = %{
        role: "assistant",
        content: "running tool",
        tool_calls: [%{name: "shell_execute", arguments: long_args}]
      }

      messages = build_conversation(5, 20) ++ [tool_msg]

      result = Compactor.maybe_compact(messages)

      tool_msgs =
        Enum.filter(result, fn
          %{tool_calls: calls} when is_list(calls) and length(calls) > 0 -> true
          _ -> false
        end)

      assert length(tool_msgs) > 0, "Expected tool message to survive compaction"
      call = hd(hd(tool_msgs).tool_calls)

      assert Map.get(call, :arguments) == "[args stripped]",
             "Expected tool call args to be replaced with '[args stripped]'"
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
      Application.delete_env(:optimal_system_agent, :compaction_warn)
      Application.delete_env(:optimal_system_agent, :compaction_aggressive)
      Application.delete_env(:optimal_system_agent, :compaction_emergency)
    end

    test "preserves hot zone messages (last 20) during pipeline" do
      Application.put_env(:optimal_system_agent, :max_context_tokens, 500)
      Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)

      # Build a conversation larger than the hot zone
      # 30 messages
      messages = build_conversation(15, 5)
      last_content = List.last(messages).content

      result = Compactor.maybe_compact(messages)

      # The last message should be present in the result
      assert Enum.any?(result, fn msg -> Map.get(msg, :content) == last_content end)
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
      Application.delete_env(:optimal_system_agent, :compaction_warn)
    end
  end

  # ---------------------------------------------------------------------------
  # Importance scoring (via public maybe_compact behavior)
  # ---------------------------------------------------------------------------

  describe "importance scoring effects" do
    test "acknowledgment-only messages are candidates for early compression" do
      # The acknowledgment pattern affects importance score.
      # We cannot inspect the score directly (private), but we verify that
      # the compactor does not crash when processing ack-only messages.
      ack_msgs = Enum.map(1..5, fn _ -> user("ok") end)
      regular_msgs = build_conversation(5)
      all_messages = ack_msgs ++ regular_msgs

      result = Compactor.maybe_compact(all_messages)
      assert is_list(result)
    end

    test "messages with tool_calls survive compression better than plain messages" do
      # Not directly testable without triggering compaction, but we verify
      # that the pipeline completes without error on mixed message types.
      Application.put_env(:optimal_system_agent, :max_context_tokens, 300)
      Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)

      tool_msg = %{
        role: "assistant",
        content: "Running tool",
        tool_calls: [%{name: "file_read", arguments: "{\"path\":\"/etc/hosts\"}"}]
      }

      messages =
        build_conversation(10, 5) ++
          [tool_msg, user("what did you find?"), asst("Here are the results")]

      result = Compactor.maybe_compact(messages)
      assert is_list(result)
      assert length(result) > 0
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
      Application.delete_env(:optimal_system_agent, :compaction_warn)
    end
  end

  # ---------------------------------------------------------------------------
  # stats/0 — GenServer metrics
  # ---------------------------------------------------------------------------

  describe "stats/0" do
    setup do
      # stats/0 requires the Compactor GenServer to be running.
      case Process.whereis(Compactor) do
        nil -> {:ok, %{available: false}}
        _pid -> {:ok, %{available: true}}
      end
    end

    test "returns a map with required metric keys", %{available: available} do
      if not available, do: flunk("Compactor GenServer not running")

      metrics = Compactor.stats()
      assert is_map(metrics)
      assert Map.has_key?(metrics, :compaction_count)
      assert Map.has_key?(metrics, :tokens_saved)
      assert Map.has_key?(metrics, :last_compacted_at)
      assert Map.has_key?(metrics, :pipeline_steps_used)
    end

    test "compaction_count and tokens_saved are non-negative integers", %{available: available} do
      if not available, do: flunk("Compactor GenServer not running")

      metrics = Compactor.stats()
      assert is_integer(metrics.compaction_count)
      assert metrics.compaction_count >= 0
      assert is_integer(metrics.tokens_saved)
      assert metrics.tokens_saved >= 0
    end

    test "pipeline_steps_used is a map", %{available: available} do
      if not available, do: flunk("Compactor GenServer not running")

      metrics = Compactor.stats()
      assert is_map(metrics.pipeline_steps_used)
    end
  end

  # ---------------------------------------------------------------------------
  # System message isolation during compaction
  # ---------------------------------------------------------------------------

  describe "system message isolation" do
    test "system messages are never discarded by compaction" do
      Application.put_env(:optimal_system_agent, :max_context_tokens, 200)
      Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)
      Application.put_env(:optimal_system_agent, :compaction_emergency, 0.0)

      system_msg = %{role: "system", content: "CRITICAL SYSTEM CONTEXT: never remove this"}
      messages = [system_msg] ++ build_conversation(15, 5)

      result = Compactor.maybe_compact(messages)

      # The system message must survive in some form
      # (either as-is or merged into a new system context notice)
      has_system_content =
        Enum.any?(result, fn msg ->
          role = Map.get(msg, :role, "")
          content = Map.get(msg, :content, "")

          role == "system" and
            (String.contains?(content, "CRITICAL") or
               String.contains?(content, "Context truncated"))
        end)

      assert has_system_content,
             "System messages should be preserved or replaced with a context notice"
    after
      Application.delete_env(:optimal_system_agent, :max_context_tokens)
      Application.delete_env(:optimal_system_agent, :compaction_warn)
      Application.delete_env(:optimal_system_agent, :compaction_emergency)
    end
  end
end
