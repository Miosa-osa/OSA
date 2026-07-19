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

  # Force the pipeline into the deterministic "background" severity tier
  # (compaction_warn=0.0 guarantees it always fires; aggressive/emergency are
  # pushed above 1.0 so a large single-run heuristic-token ratio never
  # escalates past background) and pick `max_context_tokens` so the
  # per-step target (0.70 * max) sits just above `target_tokens` — i.e. the
  # pipeline compacts down to roughly `target_tokens` and then STOPS,
  # without cascading into later steps (compress_cold / emergency_truncate)
  # that this test isn't exercising. Computed from real
  # `Compactor.estimate_tokens/1` measurements so it never depends on the
  # internal token-estimation heuristic's exact constants.
  defp force_background_stop_at(target_tokens) do
    Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)
    Application.put_env(:optimal_system_agent, :compaction_aggressive, 1.1)
    Application.put_env(:optimal_system_agent, :compaction_emergency, 1.1)
    Application.put_env(:optimal_system_agent, :max_context_tokens, round(target_tokens / 0.70))
  end

  defp clear_severity_env do
    Application.delete_env(:optimal_system_agent, :compaction_warn)
    Application.delete_env(:optimal_system_agent, :compaction_aggressive)
    Application.delete_env(:optimal_system_agent, :compaction_emergency)
    Application.delete_env(:optimal_system_agent, :max_context_tokens)
  end

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

  # ---------------------------------------------------------------------------
  # P3 — Verbatim latest user-query preservation (grok summary.rs wrap_user_query)
  # ---------------------------------------------------------------------------

  describe "P3 — verbatim latest user-query preservation" do
    test "prepends the raw latest user message in <user_query> tags, untouched by the LLM" do
      marker = "LATEST_QUERY_MARKER_#{System.unique_integer([:positive])}"
      latest_content = "Please continue: #{marker}"
      # 71 messages so the cold zone (total - 50 > 0) actually triggers.
      messages = build_conversation(35, 5) ++ [user(latest_content)]

      # Stop right after compress_cold — the "rest" (verbatim) tail is the
      # last 50 messages. Target the midpoint between `rest_tokens` (post
      # cold-zone-compression size) and the pre-compaction total, so the
      # pipeline is guaranteed to both (a) need compression at all and (b)
      # stop once the cold zone has collapsed, without cascading into
      # emergency_truncate and risking dropping the freshly-created
      # (non-turn-anchored) summary message.
      rest_tokens = messages |> Enum.take(-50) |> Compactor.estimate_tokens()
      total_tokens = Compactor.estimate_tokens(messages)
      assert rest_tokens < total_tokens, "test fixture must actually require cold-zone compression"
      target = rest_tokens + div(total_tokens - rest_tokens, 2)
      force_background_stop_at(target)

      result = Compactor.maybe_compact(messages)

      summary_msg =
        Enum.find(result, fn m ->
          String.contains?(Map.get(m, :content, ""), "[Context Summary]")
        end)

      assert summary_msg, "expected a [Context Summary] system message after compaction"
      content = Map.get(summary_msg, :content)

      assert String.contains?(content, "<user_query>\n#{latest_content}\n</user_query>"),
             "expected the latest user message wrapped verbatim in <user_query> tags"

      # It must be PREPENDED (structurally separate from, and before) the
      # LLM-produced body — not interleaved into the paraphrased section.
      [before_tag, after_tag] = String.split(content, "</user_query>", parts: 2)
      assert String.trim(after_tag) != "", "expected an LLM-produced body after the user_query block"
      assert String.starts_with?(String.trim(before_tag), "[Context Summary]\n<user_query>")

      # The raw text must appear exactly once — it was excluded from the
      # summarized span, so nothing downstream duplicated/paraphrased it.
      assert content |> String.split(marker) |> length() == 2

      # The latest message itself must also still be present verbatim in the
      # preserved (hot) tail — compaction never removes the true latest turn.
      assert Enum.any?(result, fn m -> Map.get(m, :content) == latest_content end)
    after
      clear_severity_env()
    end
  end

  # ---------------------------------------------------------------------------
  # P4 — Token-budgeted, turn-aware tail selection
  # (opencode compaction.ts select/splitTurn; grok select.rs select_tail)
  # ---------------------------------------------------------------------------

  describe "P4 — token-budgeted, turn-aware tail selection" do
    test "keeps whole recent turns verbatim when they fit within the token budget" do
      # Substantial filler per message: the warm-zone group-summarization
      # step only fires when a group's tokens exceed a 200-token floor (see
      # `summarize_in_groups/2`) — tiny messages would just pass through
      # verbatim, silently defeating this test's assertions.
      filler = String.duplicate("filler word ", 40)

      turns =
        for i <- 1..8 do
          [
            user("Turn #{i} question, marker T#{i}U #{filler}"),
            asst("Turn #{i} answer, marker T#{i}A #{filler}")
          ]
        end

      messages = List.flatten(turns)

      last_three = turns |> Enum.slice(-3, 3) |> List.flatten()
      last_four = turns |> Enum.slice(-4, 4) |> List.flatten()

      # Budget fits exactly the last 3 whole turns but not a 4th.
      budget = Compactor.estimate_tokens(last_three) + 5
      assert budget < Compactor.estimate_tokens(last_four),
             "test fixture must make the 4th-from-last turn genuinely not fit"

      Application.put_env(:optimal_system_agent, :compaction_preserve_recent_tokens, budget)

      # Stop right after summarize_warm — target a bit above the expected
      # post-summarization size (kept turns + a handful of short
      # "[Warm Summary]" stub entries) so the pipeline doesn't cascade into
      # emergency_truncate afterward.
      force_background_stop_at(Compactor.estimate_tokens(last_three) + 300)

      result = Compactor.maybe_compact(messages)
      contents = Enum.map(result, &Map.get(&1, :content, ""))

      for i <- 6..8 do
        assert Enum.any?(contents, &String.contains?(&1, "T#{i}U")),
               "turn #{i} user message should survive verbatim"

        assert Enum.any?(contents, &String.contains?(&1, "T#{i}A")),
               "turn #{i} assistant message should survive verbatim"
      end

      refute Enum.any?(contents, &String.contains?(&1, "T1U")),
             "the oldest turn should not survive verbatim"
    after
      Application.delete_env(:optimal_system_agent, :compaction_preserve_recent_tokens)
      clear_severity_env()
    end

    test "splits an oversized turn to fit the budget, keeping only the newest-fitting suffix" do
      small_turns =
        for i <- 1..6, do: [user("small turn #{i}"), asst("small reply #{i}")]

      filler = String.duplicate("word ", 300)

      tool_call_1 = %{role: "assistant", content: "", tool_calls: [%{name: "shell", arguments: "call1"}]}
      tool_result_1 = %{role: "tool", content: filler <> " TOOL1_MARKER", tool_call_id: "t1", name: "shell"}
      tool_call_2 = %{role: "assistant", content: "", tool_calls: [%{name: "shell", arguments: "call2"}]}
      tool_result_2 = %{role: "tool", content: filler <> " TOOL2_MARKER", tool_call_id: "t2", name: "shell"}
      final_reply = asst("FINAL_TAIL_MARKER short reply")

      oversized_turn = [
        user("Oversized turn start"),
        tool_call_1,
        tool_result_1,
        tool_call_2,
        tool_result_2,
        final_reply
      ]

      messages = List.flatten(small_turns) ++ oversized_turn

      final_only_tokens = Compactor.estimate_tokens([final_reply])
      whole_turn_tokens = Compactor.estimate_tokens(oversized_turn)
      budget = final_only_tokens + 20

      assert budget < whole_turn_tokens,
             "test fixture must make the newest turn genuinely oversized for its budget"

      Application.put_env(:optimal_system_agent, :compaction_preserve_recent_tokens, budget)
      force_background_stop_at(final_only_tokens + 300)

      result = Compactor.maybe_compact(messages)
      contents = Enum.map(result, &Map.get(&1, :content, ""))

      assert Enum.any?(contents, &String.contains?(&1, "FINAL_TAIL_MARKER")),
             "the newest message of the oversized turn must survive verbatim"

      refute Enum.any?(contents, &String.contains?(&1, "TOOL1_MARKER")),
             "an early message of the oversized turn should have been dropped/summarized, not kept verbatim"
    after
      Application.delete_env(:optimal_system_agent, :compaction_preserve_recent_tokens)
      clear_severity_env()
    end
  end

  # ---------------------------------------------------------------------------
  # P7 — Divide-and-conquer chunked cold-zone summarization + validation
  # (grok inter_compaction + history/validate.rs)
  # ---------------------------------------------------------------------------

  describe "P7 — divide-and-conquer chunked cold-zone summarization" do
    test "chunks a large cold zone into balanced <chunk_summary> blocks" do
      Application.put_env(:optimal_system_agent, :compaction_chunk_token_limit, 30)

      # 70 messages: cold_end = total - 50 = 20 (well above the 30-token chunk limit)
      messages = build_conversation(35, 8)

      rest_tokens = messages |> Enum.take(-50) |> Compactor.estimate_tokens()
      total_tokens = Compactor.estimate_tokens(messages)
      force_background_stop_at(rest_tokens + div(total_tokens - rest_tokens, 2))

      result = Compactor.maybe_compact(messages)

      summary_msg =
        Enum.find(result, fn m ->
          String.contains?(Map.get(m, :content, ""), "[Context Summary]")
        end)

      assert summary_msg
      content = Map.get(summary_msg, :content)

      open = (content |> String.split("<chunk_summary") |> length()) - 1
      close = (content |> String.split("</chunk_summary>") |> length()) - 1

      assert open > 1,
             "expected the cold zone to be chunked into more than one <chunk_summary> block"

      assert open == close, "<chunk_summary> tags must be balanced (open=#{open}, close=#{close})"
    after
      clear_severity_env()
      Application.delete_env(:optimal_system_agent, :compaction_chunk_token_limit)
    end

    test "falls back to the single-call path when the cold zone fits in one chunk" do
      # default chunk limit (3_000 tokens) — this cold zone easily fits in one chunk
      messages = build_conversation(35, 8)

      rest_tokens = messages |> Enum.take(-50) |> Compactor.estimate_tokens()
      total_tokens = Compactor.estimate_tokens(messages)
      force_background_stop_at(rest_tokens + div(total_tokens - rest_tokens, 2))

      result = Compactor.maybe_compact(messages)

      summary_msg =
        Enum.find(result, fn m ->
          String.contains?(Map.get(m, :content, ""), "[Context Summary]")
        end)

      assert summary_msg
      refute String.contains?(Map.get(summary_msg, :content), "<chunk_summary"),
             "a short cold zone should use the single-call path, not divide-and-conquer"
    after
      clear_severity_env()
    end
  end
end
