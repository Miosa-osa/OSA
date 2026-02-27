defmodule OptimalSystemAgent.Integration.ConversationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Signal.{Classifier, NoiseFilter}
  alias OptimalSystemAgent.Agent.{Context, Compactor, Workflow}

  # ---------------------------------------------------------------------------
  # Building an app — full conversation flow (deterministic classifier)
  # ---------------------------------------------------------------------------

  describe "building an app — full conversation flow" do
    test "user request to build a REST API is classified correctly" do
      message = "Build me a REST API for a todo app with CRUD endpoints"
      signal = Classifier.classify(message, :cli)

      assert signal.mode == :build
      assert signal.weight >= 0.5
      assert signal.format == :command
      assert {:signal, _} = NoiseFilter.filter(message)
    end

    test "follow-up technical question during build is classified as question type" do
      message = "Should I use PostgreSQL or SQLite for the database?"
      signal = Classifier.classify(message, :cli)

      assert signal.type == "question"
      assert signal.weight >= 0.5
    end

    test "fix command is MAINTAIN mode" do
      message = "Fix the authentication bug — users cant log in after the migration"
      signal = Classifier.classify(message, :cli)

      assert signal.mode == :maintain
      assert signal.type == "issue"
    end

    test "performance analysis request is ANALYZE mode" do
      message = "Analyze the API response times and show me which endpoints are slowest"
      signal = Classifier.classify(message, :cli)

      assert signal.mode == :analyze
    end

    test "run command is EXECUTE mode" do
      message = "run the deployment script now"
      signal = Classifier.classify(message, :cli)

      assert signal.mode == :execute
    end

    test "update command is MAINTAIN mode" do
      # Note: 'update' triggers :maintain, but keywords like 'run' fire :execute first
      # in the classify_mode cond. Use a message with only the maintain keyword.
      message = "update the configuration file for the deployment"
      signal = Classifier.classify(message, :cli)

      assert signal.mode == :maintain
    end

    test "create command is BUILD mode" do
      message = "create a new database migration for the users table"
      signal = Classifier.classify(message, :cli)

      assert signal.mode == :build
    end

    test "multi-step request produces a valid 5-tuple signal" do
      message = "Build me a complete REST API from scratch with authentication and deployment"
      signal = Classifier.classify(message, :cli)

      assert %Classifier{} = signal
      assert signal.mode in [:build, :execute, :analyze, :assist, :maintain]
      assert signal.genre in [:direct, :inform, :commit, :decide, :express]
      assert is_binary(signal.type)
      assert signal.format in [:command, :message, :notification, :document, :transcript]
      assert is_float(signal.weight)
      assert signal.weight >= 0.0 and signal.weight <= 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # Noise filtering — real conversations
  # ---------------------------------------------------------------------------

  describe "noise filtering — real conversations" do
    test "casual greetings are filtered as noise" do
      assert {:noise, _} = NoiseFilter.filter("hey")
      assert {:noise, _} = NoiseFilter.filter("hello")
      assert {:noise, _} = NoiseFilter.filter("good morning")
    end

    test "short greetings under 3 chars are filtered as noise (:too_short)" do
      assert {:noise, :too_short} = NoiseFilter.filter("hi")
    end

    test "acknowledgments are filtered as noise" do
      assert {:noise, _} = NoiseFilter.filter("sure")
      assert {:noise, _} = NoiseFilter.filter("thanks")
      assert {:noise, _} = NoiseFilter.filter("yeah")
    end

    test "short acknowledgments under 3 chars are filtered as noise (:too_short)" do
      assert {:noise, :too_short} = NoiseFilter.filter("ok")
    end

    test "substantive messages pass through" do
      assert {:signal, w1} = NoiseFilter.filter("Create a new user authentication system with JWT tokens")
      assert w1 >= 0.5

      assert {:signal, w2} = NoiseFilter.filter("What is the best approach for handling file uploads in Elixir?")
      assert w2 >= 0.5

      assert {:signal, w3} = NoiseFilter.filter("The production database is running out of disk space")
      assert w3 >= 0.5
    end

    test "urgent messages get high weight" do
      assert {:signal, weight} = NoiseFilter.filter("URGENT: Production is down, all services returning 500 errors")
      assert weight >= 0.7
    end

    test "technical question passes through as signal" do
      assert {:signal, _} = NoiseFilter.filter("how do I configure the database connection pool?")
    end

    test "empty string is noise with :empty reason" do
      assert {:noise, :empty} = NoiseFilter.filter("")
    end

    test "noise filter always returns a tagged two-tuple" do
      for msg <- ["", "hi", "hello", "build me an API", "urgent fix needed"] do
        result = NoiseFilter.filter(msg)
        assert match?({tag, _} when tag in [:noise, :signal], result),
               "Expected tagged tuple for #{inspect(msg)}, got #{inspect(result)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Context builder — token budgeting
  # ---------------------------------------------------------------------------

  describe "context builder — token budgeting" do
    test "builds context with signal classification injected" do
      state = %{
        session_id: "test-session-1",
        user_id: "user-1",
        channel: :cli,
        messages: [
          %{role: "user", content: "Build me a REST API"}
        ]
      }

      signal = Classifier.classify("Build me a REST API", :cli)
      context = Context.build(state, signal)

      assert is_map(context)
      assert is_list(context.messages)

      # System message should be first
      [system_msg | _rest] = context.messages
      assert system_msg.role == "system"

      # Identity block always present
      assert String.contains?(system_msg.content, "OptimalSystemAgent")

      # Signal classification block is injected for BUILD mode
      assert String.contains?(system_msg.content, "BUILD")
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

      # Without a signal, "Current Signal Classification" section is absent
      refute String.contains?(system_msg.content, "Current Signal Classification")
    end

    test "build with signal injects signal classification block" do
      state = %{
        session_id: "test-with-signal",
        user_id: nil,
        channel: :cli,
        messages: []
      }

      signal = Classifier.classify("analyze the logs", :cli)
      context = Context.build(state, signal)
      [system_msg | _] = context.messages

      assert String.contains?(system_msg.content, "Current Signal Classification")
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
          %{role: (if rem(i, 2) == 0, do: "assistant", else: "user"), content: content}
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
      long = Compactor.estimate_tokens("This is a much longer message with many words and substantial content that should have significantly more tokens than a short greeting")

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
      result = Workflow.context_block("nonexistent-session-xyz-#{System.unique_integer([:positive])}")
      assert result == nil
    end

    test "should_create_workflow? returns false for nil input" do
      refute Workflow.should_create_workflow?(nil)
    end

    test "should_create_workflow? returns false for empty string" do
      refute Workflow.should_create_workflow?("")
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-channel classification
  # ---------------------------------------------------------------------------

  describe "multi-channel classification" do
    test "same message produces consistent mode across cli, telegram, and discord" do
      message = "fix the login bug — users cannot authenticate"

      cli_signal = Classifier.classify(message, :cli)
      telegram_signal = Classifier.classify(message, :telegram)
      discord_signal = Classifier.classify(message, :discord)

      assert cli_signal.mode == telegram_signal.mode
      assert cli_signal.mode == discord_signal.mode
    end

    test "same message produces consistent genre across channels" do
      message = "fix the login bug — users cannot authenticate"

      cli_signal = Classifier.classify(message, :cli)
      telegram_signal = Classifier.classify(message, :telegram)

      assert cli_signal.genre == telegram_signal.genre
    end

    test "same message produces consistent type across channels" do
      message = "fix the login bug — users cannot authenticate"

      cli_signal = Classifier.classify(message, :cli)
      discord_signal = Classifier.classify(message, :discord)

      assert cli_signal.type == discord_signal.type
    end

    test "format differs by channel: cli is :command, telegram is :message" do
      message = "analyze the performance metrics"

      cli_signal = Classifier.classify(message, :cli)
      telegram_signal = Classifier.classify(message, :telegram)

      assert cli_signal.format == :command
      assert telegram_signal.format == :message
    end

    test "format for webhook channel is :notification" do
      signal = Classifier.classify("incoming event payload", :webhook)
      assert signal.format == :notification
    end

    test "all supported channels produce a valid format" do
      channels = [
        :cli,
        :telegram,
        :discord,
        :slack,
        :whatsapp,
        :signal,
        :matrix,
        :email,
        :qq,
        :dingtalk,
        :feishu,
        :webhook
      ]

      Enum.each(channels, fn channel ->
        signal = Classifier.classify("test message for channel", channel)

        assert signal.format in [:command, :message, :notification, :document, :transcript],
               "Unexpected format #{signal.format} for channel #{channel}"

        assert signal.channel == channel,
               "Expected channel #{channel}, got #{signal.channel}"
      end)
    end

    test "channel is stored on the signal struct" do
      signal = Classifier.classify("run the tests", :slack)
      assert signal.channel == :slack
    end
  end

  # ---------------------------------------------------------------------------
  # Weight calculation — realistic messages
  # ---------------------------------------------------------------------------

  describe "weight calculation — realistic messages" do
    test "production incident with URGENT keyword gets high weight" do
      weight =
        Classifier.calculate_weight(
          "URGENT: Database connection pool exhausted, all API requests timing out"
        )

      assert weight >= 0.7
    end

    test "technical question with question mark gets medium-to-high weight" do
      weight = Classifier.calculate_weight("How do I configure the connection pool size in Ecto?")

      assert weight >= 0.5
    end

    test "short greeting gets low weight" do
      weight = Classifier.calculate_weight("hi")
      assert weight < 0.3
    end

    test "complex multi-part request gets high weight due to length bonus" do
      weight =
        Classifier.calculate_weight(
          "I need you to analyze our Q3 revenue data, compare it with Q2, " <>
            "identify the top 3 growth drivers, and create a presentation deck " <>
            "with charts for the board meeting tomorrow"
        )

      assert weight >= 0.6
    end

    test "critical urgency keyword adds 0.2 bonus" do
      base = Classifier.calculate_weight("fix the bug")
      with_critical = Classifier.calculate_weight("critical fix the bug")

      assert with_critical > base
      assert with_critical - base >= 0.15
    end

    test "question mark adds 0.15 bonus" do
      base = Classifier.calculate_weight("analyze the logs")
      with_question = Classifier.calculate_weight("analyze the logs?")

      # Question bonus is 0.15 plus a tiny length bonus for the extra char
      diff = with_question - base
      assert_in_delta diff, 0.15 + (1 / 500.0), 0.001
    end

    test "weight is always between 0.0 and 1.0" do
      messages = [
        "",
        "hi",
        "Run the tests now!",
        "URGENT CRITICAL EMERGENCY: everything is broken immediately asap",
        String.duplicate("analyze ", 200)
      ]

      Enum.each(messages, fn msg ->
        w = Classifier.calculate_weight(msg)
        assert w >= 0.0 and w <= 1.0,
               "Weight #{w} out of range for message: #{String.slice(msg, 0, 40)}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Signal classification — documented deterministic behavior
  # ---------------------------------------------------------------------------

  describe "signal classification — deterministic keyword matching" do
    test "'help me build this feature' — 'build' keyword fires BUILD mode" do
      # Deterministic path: 'build' is checked before 'help' in mode classification.
      # In the classify_mode cond, BUILD keywords are checked first.
      signal = Classifier.classify("help me build this feature")
      assert signal.mode == :build
    end

    test "'help me understand this' without build keywords falls through to :assist" do
      signal = Classifier.classify("help me understand this")
      assert signal.mode == :assist
    end

    test "question mark in message produces type 'question'" do
      signal = Classifier.classify("Can you run the test suite?")
      assert signal.type == "question"
    end

    test "run keyword triggers :execute mode" do
      signal = Classifier.classify("Can you run the test suite?")
      assert signal.mode == :execute
    end

    test "emotional + technical message with fix keyword resolves to :maintain" do
      signal =
        Classifier.classify(
          "This is terrible — the login page has been broken for 3 days, fix it immediately!"
        )

      assert signal.mode == :maintain
    end

    test "emotional message with exclamation resolves to :direct genre" do
      signal =
        Classifier.classify(
          "This is terrible — the login page has been broken for 3 days, fix it immediately!"
        )

      # Ends with '!' → :direct genre
      assert signal.genre == :direct
    end

    test "issue keywords in message produce 'issue' type" do
      signal =
        Classifier.classify(
          "This is terrible — the login page has been broken for 3 days, fix it immediately!"
        )

      assert signal.type == "issue"
    end

    test "mode classification is prioritized in cond order: build > execute > analyze > maintain > assist" do
      # 'build' fires before 'update' in the cond
      signal = Classifier.classify("build and update the schema")
      assert signal.mode == :build
    end

    test "analyze keyword produces :analyze mode" do
      signal = Classifier.classify("analyze the API response times")
      assert signal.mode == :analyze
    end

    test "sync keyword produces :execute mode" do
      signal = Classifier.classify("sync the database now")
      assert signal.mode == :execute
    end
  end
end
