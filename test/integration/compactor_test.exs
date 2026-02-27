defmodule OptimalSystemAgent.Integration.CompactorTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Compactor

  # ---------------------------------------------------------------------------
  # Token estimation — strings
  # ---------------------------------------------------------------------------

  describe "token estimation — strings" do
    test "estimate_tokens returns positive integer for non-empty string" do
      assert Compactor.estimate_tokens("hello") > 0
    end

    test "estimate_tokens returns 0 for empty string" do
      assert Compactor.estimate_tokens("") == 0
    end

    test "estimate_tokens returns 0 for nil" do
      assert Compactor.estimate_tokens(nil) == 0
    end

    test "pangram has reasonable token estimate (> 5 tokens)" do
      result = Compactor.estimate_tokens("The quick brown fox jumps over the lazy dog.")
      assert result > 5
    end

    test "longer messages have more tokens than shorter messages" do
      short = Compactor.estimate_tokens("hi")

      long =
        Compactor.estimate_tokens(
          "This is a much longer message with many words and substantial content that should have significantly more tokens than a short greeting"
        )

      assert long > short
    end

    test "token estimate is proportional to word count" do
      one_word = Compactor.estimate_tokens("hello")
      ten_words = Compactor.estimate_tokens("one two three four five six seven eight nine ten")

      # 10 words should estimate roughly 10x more tokens than 1 word
      assert ten_words > one_word * 5
    end

    test "estimate_tokens uses words * 1.3 + punctuation * 0.5 heuristic" do
      # "Hello, world!" = 2 words, 2 punctuation chars
      # Expected: round(2 * 1.3 + 2 * 0.5) = round(2.6 + 1.0) = round(3.6) = 4
      result = Compactor.estimate_tokens("Hello, world!")
      assert result == 4
    end

    test "unicode content is handled without raising" do
      result = Compactor.estimate_tokens("Analyze the \u{1F4CA} metrics for Q3")
      assert is_integer(result)
      assert result > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Token estimation — message lists
  # ---------------------------------------------------------------------------

  describe "token estimation — message lists" do
    test "estimate_tokens for an empty message list returns 0" do
      assert Compactor.estimate_tokens([]) == 0
    end

    test "estimate_tokens for a message list returns a positive integer" do
      messages = [
        %{role: "user", content: "Hello, how are you?"},
        %{role: "assistant", content: "I am doing well, thanks for asking!"}
      ]

      tokens = Compactor.estimate_tokens(messages)
      assert tokens > 0
      assert is_integer(tokens)
    end

    test "message list with more content has more tokens" do
      small = Compactor.estimate_tokens([%{role: "user", content: "hi"}])

      large =
        Compactor.estimate_tokens([
          %{role: "user", content: String.duplicate("word ", 100)},
          %{role: "assistant", content: String.duplicate("response ", 100)}
        ])

      assert large > small
    end

    test "each message adds 4 tokens of per-message overhead" do
      single = Compactor.estimate_tokens([%{role: "user", content: ""}])
      double = Compactor.estimate_tokens([%{role: "user", content: ""}, %{role: "assistant", content: ""}])

      # Double should be exactly 4 more than single (second message overhead only)
      assert double == single + 4
    end

    test "messages with tool_calls are handled without raising" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{name: "shell_execute", arguments: "{\"command\": \"ls\"}"}]
        }
      ]

      result = Compactor.estimate_tokens(messages)
      assert is_integer(result)
      assert result > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Utilization
  # ---------------------------------------------------------------------------

  describe "utilization" do
    test "empty message list has 0.0% utilization" do
      assert Compactor.utilization([]) == 0.0
    end

    test "utilization is a float" do
      util = Compactor.utilization([%{role: "user", content: "hello"}])
      assert is_float(util)
    end

    test "utilization is between 0.0 and 100.0" do
      messages = [%{role: "user", content: "short message"}]
      util = Compactor.utilization(messages)

      assert util >= 0.0
      assert util <= 100.0
    end

    test "utilization increases with more content" do
      small = Compactor.utilization([%{role: "user", content: "hi"}])

      large =
        Compactor.utilization(
          for i <- 1..50 do
            %{role: "user", content: String.duplicate("word ", 100) <> "#{i}"}
          end
        )

      assert large > small
    end

    test "utilization for a single short message is less than 1%" do
      util = Compactor.utilization([%{role: "user", content: "short message"}])
      assert util < 1.0
    end

    test "utilization for 200 large messages is substantially above 0%" do
      # 200 messages with 50 repetitions of content creates a large conversation.
      # The exact percentage depends on the compiled @max_tokens threshold, but
      # it must always be well above 50% for this volume of content.
      messages =
        for i <- 1..200 do
          content = String.duplicate("This is message number #{i} with content. ", 50)
          %{role: (if rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
        end

      util = Compactor.utilization(messages)
      assert util > 50.0
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_compact — core compaction behavior
  # ---------------------------------------------------------------------------

  describe "maybe_compact — core behavior" do
    test "returns empty list unchanged" do
      assert Compactor.maybe_compact([]) == []
    end

    test "returns nil unchanged (nil pass-through via rescue)" do
      assert Compactor.maybe_compact(nil) == nil
    end

    test "returns short conversation unchanged (under 80% threshold)" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there! How can I help you today?"}
      ]

      result = Compactor.maybe_compact(messages)
      assert length(result) == length(messages)
    end

    test "returns a list for any list input" do
      for messages <- [
            [],
            [%{role: "user", content: "x"}],
            [%{role: "user", content: "hello"}, %{role: "assistant", content: "world"}]
          ] do
        result = Compactor.maybe_compact(messages)
        assert is_list(result), "Expected list for #{inspect(messages)}"
      end
    end

    test "compacts a conversation that exceeds the 80% utilization threshold" do
      # 200 messages x 50 repetitions ≈ 85% of max context
      messages =
        for i <- 1..200 do
          content = String.duplicate("This is message number #{i} with some content. ", 50)
          %{role: (if rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
        end

      result = Compactor.maybe_compact(messages)

      assert length(result) < length(messages),
             "Expected fewer messages after compaction, got #{length(result)}"
    end

    test "compacted result still contains messages" do
      messages =
        for i <- 1..200 do
          content = String.duplicate("This is message number #{i} with some content. ", 50)
          %{role: (if rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
        end

      result = Compactor.maybe_compact(messages)
      assert length(result) > 0
    end

    test "compacted messages are all maps with a :role key" do
      messages =
        for i <- 1..200 do
          content = String.duplicate("Message #{i} repeated content for bulk. ", 50)
          %{role: (if rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
        end

      result = Compactor.maybe_compact(messages)

      Enum.each(result, fn msg ->
        assert is_map(msg), "Expected map, got #{inspect(msg)}"
        assert Map.has_key?(msg, :role) or Map.has_key?(msg, "role"),
               "Expected :role key in #{inspect(msg)}"
      end)
    end

    test "compaction does not raise on messages with tool calls" do
      messages =
        for i <- 1..5 do
          if rem(i, 3) == 0 do
            %{
              role: "assistant",
              content: "",
              tool_calls: [%{name: "shell_execute", arguments: "{\"command\": \"ls\"}"}]
            }
          else
            %{role: "user", content: "Message #{i}"}
          end
        end

      result = Compactor.maybe_compact(messages)
      assert is_list(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Stats
  # ---------------------------------------------------------------------------

  describe "stats" do
    test "stats returns a map" do
      stats = Compactor.stats()
      assert is_map(stats)
    end

    test "stats includes compaction_count key" do
      stats = Compactor.stats()
      assert Map.has_key?(stats, :compaction_count)
    end

    test "stats includes tokens_saved key" do
      stats = Compactor.stats()
      assert Map.has_key?(stats, :tokens_saved)
    end

    test "stats includes last_compacted_at key" do
      stats = Compactor.stats()
      assert Map.has_key?(stats, :last_compacted_at)
    end

    test "stats includes pipeline_steps_used key" do
      stats = Compactor.stats()
      assert Map.has_key?(stats, :pipeline_steps_used)
    end

    test "compaction_count is a non-negative integer" do
      stats = Compactor.stats()
      assert is_integer(stats.compaction_count)
      assert stats.compaction_count >= 0
    end

    test "tokens_saved is a non-negative integer" do
      stats = Compactor.stats()
      assert is_integer(stats.tokens_saved)
      assert stats.tokens_saved >= 0
    end

    test "pipeline_steps_used is a map" do
      stats = Compactor.stats()
      assert is_map(stats.pipeline_steps_used)
    end

    test "compaction_count increments after a compaction occurs" do
      initial_stats = Compactor.stats()
      initial_count = initial_stats.compaction_count

      # Use "with some content." to ensure we exceed the 80% utilization threshold.
      # (85.8% at 128K max tokens)
      messages =
        for i <- 1..200 do
          content = String.duplicate("This is message number #{i} with some content. ", 50)
          %{role: (if rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
        end

      Compactor.maybe_compact(messages)

      # Give the async GenServer.cast time to record the compaction metrics
      Process.sleep(300)

      updated_stats = Compactor.stats()
      assert updated_stats.compaction_count > initial_count,
             "Expected compaction_count to increment from #{initial_count}, got #{updated_stats.compaction_count}"
    end
  end
end
