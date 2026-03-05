defmodule OptimalSystemAgent.Integration.ConversationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.{Context, Compactor, Workflow}

  # ---------------------------------------------------------------------------
  # Context builder — token budgeting
  # ---------------------------------------------------------------------------

  describe "context builder — token budgeting" do
    test "builds context with system message first" do
      state = %{
        session_id: "test-session-1",
        user_id: "user-1",
        channel: :cli,
        messages: [
          %{role: "user", content: "Build me a REST API"}
        ]
      }

      context = Context.build(state, nil)

      assert is_map(context)
      assert is_list(context.messages)

      # System message should be first
      [system_msg | _rest] = context.messages
      assert system_msg.role == "system"

      # Identity block always present (via Soul module)
      assert String.contains?(system_msg.content, "Optimal System Agent") or
               String.contains?(system_msg.content, "OSA")

      # SYSTEM.md static content references Signal Theory modes
      assert String.contains?(system_msg.content, "BUILD") or
               String.contains?(system_msg.content, "EXECUTE") or
               String.contains?(system_msg.content, "ANALYZE")
    end

    test "context includes the channel name in runtime block" do
      state = %{
        session_id: "test-session-2",
        user_id: "user-2",
        channel: :telegram,
        messages: []
      }

      context = Context.build(state, nil)
      [system_msg | _] = context.messages

      assert String.contains?(system_msg.content, "telegram")
    end

    test "context includes the session id in runtime block" do
      session_id = "test-session-context-#{System.unique_integer([:positive])}"

      state = %{
        session_id: session_id,
        user_id: nil,
        channel: :cli,
        messages: []
      }

      context = Context.build(state, nil)
      [system_msg | _] = context.messages

      assert String.contains?(system_msg.content, session_id)
    end

    test "build returns messages list with system message first" do
      state = %{
        session_id: "test-session-3",
        user_id: nil,
        channel: :cli,
        messages: [
          %{role: "user", content: "hello"},
          %{role: "assistant", content: "world"}
        ]
      }

      context = Context.build(state, nil)

      # Total messages = system + conversation messages
      assert length(context.messages) == 3
      assert List.first(context.messages).role == "system"
    end

    test "token_budget returns a breakdown map with expected keys" do
      state = %{
        session_id: "test-session-budget",
        user_id: nil,
        channel: :cli,
        messages: [%{role: "user", content: "hello world"}]
      }

      budget = Context.token_budget(state)

      assert is_map(budget)
      assert Map.has_key?(budget, :max_tokens)
      assert Map.has_key?(budget, :conversation_tokens)
      assert Map.has_key?(budget, :system_prompt_budget)
      assert Map.has_key?(budget, :total_tokens)
    end

    test "token_budget reports sensible numeric values" do
      state = %{
        session_id: "test-session-budget-2",
        user_id: nil,
        channel: :cli,
        messages: [%{role: "user", content: "hello world"}]
      }

      budget = Context.token_budget(state)

      assert budget.max_tokens > 0
      assert budget.conversation_tokens >= 0
      assert budget.system_prompt_budget > 0
      assert budget.total_tokens > 0
      assert budget.total_tokens <= budget.max_tokens
    end

    test "build with nil signal omits the signal classification block" do
      state = %{
        session_id: "test-no-signal",
        user_id: nil,
        channel: :cli,
        messages: []
      }

      context = Context.build(state, nil)
      [system_msg | _] = context.messages

      # Without a signal, signal overlay section is absent
      refute String.contains?(system_msg.content, "Active Signal:")
    end

    test "build without signal — LLM self-classifies via SYSTEM.md" do
      state = %{
        session_id: "test-no-overlay",
        user_id: nil,
        channel: :cli,
        messages: []
      }

      # No signal is injected — Signal Theory instructions are in the static SYSTEM.md prompt
      context = Context.build(state, nil)
      [system_msg | _] = context.messages

      refute String.contains?(system_msg.content, "Active Signal:")
      # Signal Theory tables are in the static base (SYSTEM.md sections 2-3)
      assert String.contains?(system_msg.content, "SIGNAL SYSTEM")
    end
  end

  # ---------------------------------------------------------------------------
  # Compactor — sliding window
  # ---------------------------------------------------------------------------

  describe "compactor — sliding window" do
    test "returns messages unchanged when under threshold" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      result = Compactor.maybe_compact(messages)
      assert length(result) == length(messages)
    end

    test "compacts when over threshold" do
      # 200 messages with 50-repetitions content hits ~85% usage (above 80% threshold)
      messages =
        for i <- 1..200 do
          content = String.duplicate("This is message number #{i} with some content. ", 50)
          %{role: if(rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
        end

      result = Compactor.maybe_compact(messages)

      # Should have fewer messages after compaction
      assert length(result) < length(messages)
    end

    test "estimate_tokens returns positive integer for non-empty string" do
      assert Compactor.estimate_tokens("hello world") > 0
    end

    test "estimate_tokens returns 0 for empty string" do
      assert Compactor.estimate_tokens("") == 0
    end

    test "estimate_tokens returns 0 for nil" do
      assert Compactor.estimate_tokens(nil) == 0
    end

    test "estimate_tokens returns more tokens for longer strings" do
      short = Compactor.estimate_tokens("hi")

      long =
        Compactor.estimate_tokens(
          "This is a much longer message with many words and substantial content that should have significantly more tokens than a short greeting"
        )

      assert long > short
    end

    test "estimate_tokens for a message list sums content correctly" do
      messages = [
        %{role: "user", content: "Hello, how are you?"},
        %{role: "assistant", content: "I am doing well, thanks for asking!"}
      ]

      tokens = Compactor.estimate_tokens(messages)

      assert tokens > 0
      assert is_integer(tokens)
    end

    test "utilization returns a float between 0.0 and 100.0" do
      messages = [%{role: "user", content: "short message"}]
      util = Compactor.utilization(messages)

      assert is_float(util)
      assert util >= 0.0
      assert util <= 100.0
    end

    test "utilization is nearly 0 for empty message list" do
      util = Compactor.utilization([])
      assert util < 1.0
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

    test "maybe_compact returns empty list for empty input" do
      assert Compactor.maybe_compact([]) == []
    end

    test "maybe_compact handles nil input without raising" do
      # nil is passed to the rescue block and returned as-is
      result = Compactor.maybe_compact(nil)
      assert result == nil
    end

    test "maybe_compact never raises on edge case inputs" do
      # All of these should succeed without raising
      assert is_list(Compactor.maybe_compact([])) or Compactor.maybe_compact([]) == []
      assert Compactor.maybe_compact(nil) == nil
      assert is_list(Compactor.maybe_compact([%{role: "user", content: "x"}]))
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow — task decomposition detection
  # ---------------------------------------------------------------------------

  describe "workflow — complex task detection" do
    test "detects complex build + system task as needing a workflow" do
      assert Workflow.should_create_workflow?(
               "Build me a complete REST API from scratch with authentication and deployment"
             )
    end

    test "detects create + full-stack task as needing a workflow" do
      assert Workflow.should_create_workflow?(
               "Create a full-stack web application with React frontend and Node backend"
             )
    end

    test "detects end-to-end pipeline task as needing a workflow" do
      assert Workflow.should_create_workflow?(
               "Implement an end-to-end CI/CD pipeline for our microservices"
             )
    end

    test "does not flag simple questions as workflows" do
      refute Workflow.should_create_workflow?("What time is it?")
    end

    test "does not flag tiny fix tasks as workflows" do
      refute Workflow.should_create_workflow?("Fix the typo in README.md")
    end

    test "does not flag simple run commands as workflows" do
      refute Workflow.should_create_workflow?("Run the tests")
    end

    test "context_block returns nil when no active workflow exists for session" do
      result =
        Workflow.context_block("nonexistent-session-xyz-#{System.unique_integer([:positive])}")

      assert result == nil
    end

    test "should_create_workflow? returns false for nil input" do
      refute Workflow.should_create_workflow?(nil)
    end

    test "should_create_workflow? returns false for empty string" do
      refute Workflow.should_create_workflow?("")
    end
  end
end
