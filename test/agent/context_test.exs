defmodule OptimalSystemAgent.Agent.ContextTest do
  @moduledoc """
  Unit tests for the two-tier context builder (Agent.Context).

  All tests operate on the pure-Elixir logic that does NOT require a running
  LLM provider.  The build/1 function calls Soul.static_base/0 and several
  optional integrations (Memory, Episodic, Tasks, etc.) — every external
  dependency is designed to degrade gracefully when unavailable, so tests
  exercise the degraded path by default.

  Tests that verify the token budget calculation mirror the arithmetic in
  context.ex directly so they serve as living documentation of that contract.

  Runs `async: false`: the "provider-specific system message format" describe
  block mutates the global `:default_provider` Application env to `:anthropic`.
  As an async test that write leaks into any concurrently-scheduled async test
  that reads the provider (e.g. Integration.ConversationTest's Context.build),
  flipping its system-message content from a string to Anthropic cache blocks.
  Serializing this module keeps the global mutation out of the async window.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context

  # Every test starts from a clean :default_provider. It is a process-global
  # Application env that this file's "provider-specific system message format"
  # describe (and other test files) set to :anthropic. A leaked non-plain-prefix
  # provider makes build/1 route the runtime block through the cached system
  # prompt and drop the current session id — which flaked "contains session id"
  # in the full suite while it passed in isolation. Reset per test; describes
  # that need a specific provider still set it themselves after this. (#208)
  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    Application.delete_env(:optimal_system_agent, :default_provider)

    on_exit(fn ->
      case prev_provider do
        nil -> Application.delete_env(:optimal_system_agent, :default_provider)
        v -> Application.put_env(:optimal_system_agent, :default_provider, v)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Minimal valid state fixture
  # ---------------------------------------------------------------------------

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "ctx-test-#{:erlang.unique_integer([:positive])}",
        channel: :cli,
        messages: [],
        plan_mode: false,
        working_dir: "/tmp",
        # Pin the context window so token_budget/1 is deterministic. Without it,
        # max_tok is derived from the GLOBALLY-active model, so an async sibling
        # test that switched the active model flipped response_reserve from 8192
        # to 4096 — the recurring `response_reserve is 8192` flake. 200k keeps
        # response_reserve at its 8192 ceiling regardless of global model state.
        effective_context_window: 200_000
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # build/1 — structural shape
  # ---------------------------------------------------------------------------

  describe "build/1 — return shape" do
    test "returns a map with a :messages key" do
      state = base_state()
      result = Context.build(state)
      assert is_map(result)
      assert Map.has_key?(result, :messages)
    end

    test ":messages list is non-empty (at least the system message)" do
      state = base_state()
      %{messages: messages} = Context.build(state)
      assert is_list(messages)
      assert length(messages) >= 1
    end

    test "first message is the system message with role 'system'" do
      state = base_state()
      %{messages: [system_msg | _]} = Context.build(state)
      assert Map.get(system_msg, :role) == "system"
    end

    test "conversation messages are appended after the system message" do
      user_msg = %{role: "user", content: "Hello there"}
      asst_msg = %{role: "assistant", content: "Hi!"}
      state = base_state(%{messages: [user_msg, asst_msg]})

      %{messages: [_system | conversation]} = Context.build(state)

      # For plain-prefix (Ollama) providers the volatile block is appended as a
      # trailing <system-reminder> message (KV-cache prefix stability), so the
      # real conversation is the head of the list; a trailing reminder may follow.
      real = Enum.reject(conversation, &String.contains?(to_string(&1.content), "<system-reminder>"))
      assert length(real) == 2
      assert List.first(real).role == "user"
      assert List.last(real).role == "assistant"
    end

    test "build/2 (with signal arg) delegates to build/1" do
      state = base_state()
      result1 = Context.build(state)
      result2 = Context.build(state, %{type: :direct})
      # Both should produce equivalent system message structure
      assert Map.get(hd(result1.messages), :role) == Map.get(hd(result2.messages), :role)
    end
  end

  # ---------------------------------------------------------------------------
  # System message format varies by provider
  # ---------------------------------------------------------------------------

  describe "build/1 — provider-specific system message format" do
    test "non-anthropic provider produces a string content system message" do
      Application.put_env(:optimal_system_agent, :default_provider, :ollama)
      state = base_state()
      %{messages: [system_msg | _]} = Context.build(state)
      # Non-anthropic: content is a binary string (concatenated)
      assert is_binary(Map.get(system_msg, :content))
    after
      Application.delete_env(:optimal_system_agent, :default_provider)
    end

    test "anthropic provider produces list content with cache_control block" do
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
      state = base_state()
      %{messages: [system_msg | _]} = Context.build(state)

      content = Map.get(system_msg, :content)

      # Anthropic path: list of content blocks
      assert is_list(content)
      static_block = List.first(content)
      assert Map.get(static_block, :type) == "text"
      assert Map.has_key?(static_block, :cache_control)
      assert Map.get(static_block.cache_control, :type) == "ephemeral"
    after
      Application.delete_env(:optimal_system_agent, :default_provider)
    end
  end

  # ---------------------------------------------------------------------------
  # Plan mode block
  # ---------------------------------------------------------------------------

  describe "build/1 — plan mode block" do
    test "plan_mode: true injects PLAN MODE section in system prompt" do
      state = base_state(%{plan_mode: true})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      assert String.contains?(prompt_text, "PLAN MODE")
    end

    test "plan_mode: false does NOT inject PLAN MODE section" do
      state = base_state(%{plan_mode: false})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      refute String.contains?(prompt_text, "PLAN MODE")
    end

    # Investigative plan mode (read tools stay ON — see PlanStore/ToolExecutor
    # mode == :plan gate): the prompt must NOT tell the model to avoid tools
    # entirely, it must tell it to investigate with read-only tools first.
    test "plan mode block is investigative — mentions read-only tools are available" do
      state = base_state(%{plan_mode: true})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      refute String.contains?(prompt_text, "Do NOT execute any actions or call any tools")
      assert String.contains?(prompt_text, "Read-only tools")
      assert String.contains?(prompt_text, "AVAILABLE")
      assert String.contains?(prompt_text, "investigat")
    end

    test "plan mode block still specifies the structured plan format" do
      state = base_state(%{plan_mode: true})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      assert String.contains?(prompt_text, "### Goal")
      assert String.contains?(prompt_text, "### Steps")
      assert String.contains?(prompt_text, "### Files")
      assert String.contains?(prompt_text, "### Risks")
      assert String.contains?(prompt_text, "### Estimate")
    end

    test "plan mode block surfaces an existing durable draft plan for the session" do
      session_id = "ctx-plan-draft-#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> File.rm(OptimalSystemAgent.Agent.PlanStore.plan_file_path(session_id)) end)

      OptimalSystemAgent.Agent.PlanStore.write_plan_file(
        session_id,
        "### Goal\nRefactor the frobnicator.\n"
      )

      state = base_state(%{plan_mode: true, session_id: session_id})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      assert String.contains?(prompt_text, "Existing draft plan")
      assert String.contains?(prompt_text, "Refactor the frobnicator.")
    end

    test "plan mode block has no existing-draft section when no plan file exists yet" do
      state = base_state(%{plan_mode: true})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      refute String.contains?(prompt_text, "Existing draft plan")
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime block — always present
  # ---------------------------------------------------------------------------

  describe "build/1 — runtime block" do
    test "system prompt contains channel identifier" do
      state = base_state(%{channel: :http})
      %{messages: [system_msg | _]} = Context.build(state)

      prompt_text = extract_system_text(system_msg)
      assert String.contains?(prompt_text, "http")
    end

    test "system prompt contains session id" do
      session_id = "ctx-runtime-session-#{:erlang.unique_integer([:positive])}"
      state = base_state(%{session_id: session_id})
      %{messages: msgs} = Context.build(state)

      # The runtime block (session id, timestamp) is emitted every turn. For
      # plain-prefix providers it rides in the trailing <system-reminder>
      # message rather than the cached system prompt — so assert it appears
      # SOMEWHERE in the assembled request, not specifically in the system block.
      all_text = Enum.map_join(msgs, "\n", &to_string(&1.content))
      assert String.contains?(all_text, session_id)
    end
  end

  # ---------------------------------------------------------------------------
  # token_budget/1 — arithmetic correctness
  # ---------------------------------------------------------------------------

  describe "token_budget/1" do
    test "returns a complete map with all expected keys" do
      state = base_state()
      budget = Context.token_budget(state)

      required_keys = [
        :max_tokens,
        :response_reserve,
        :conversation_tokens,
        :static_base_tokens,
        :dynamic_context_tokens,
        :system_prompt_budget,
        :system_prompt_actual,
        :total_tokens,
        :utilization_pct,
        :headroom,
        :blocks
      ]

      for key <- required_keys do
        assert Map.has_key?(budget, key), "Missing key: #{key}"
      end
    end

    test "response_reserve is 8192" do
      state = base_state()
      budget = Context.token_budget(state)
      assert budget.response_reserve == 8_192
    end

    test "conversation_tokens is 0 when messages list is empty" do
      state = base_state(%{messages: []})
      budget = Context.token_budget(state)
      assert budget.conversation_tokens == 0
    end

    test "conversation_tokens increases with message content" do
      state_empty = base_state(%{messages: []})

      state_full =
        base_state(%{messages: [%{role: "user", content: String.duplicate("word ", 200)}]})

      budget_empty = Context.token_budget(state_empty)
      budget_full = Context.token_budget(state_full)

      assert budget_full.conversation_tokens > budget_empty.conversation_tokens
    end

    test "system_prompt_budget equals max_tokens - response_reserve - conversation_tokens" do
      state = base_state(%{messages: []})
      budget = Context.token_budget(state)

      expected = budget.max_tokens - budget.response_reserve - budget.conversation_tokens
      assert budget.system_prompt_budget == expected
    end

    test "total_tokens equals static + dynamic + conversation + reserve + TOOLS" do
      # The tool array used to be missing from this sum, and this test pinned
      # its absence. The schemas are sent on every request — and under the
      # `:native_tools` variant they are the ONLY place that content exists,
      # since the prose duplicating them is stripped from the prompt — so
      # omitting them made the meter read 41.7% low (15,496 tokens against a
      # reported 37,172) and compaction fire later than it believed.
      state = base_state()
      budget = Context.token_budget(state)

      expected =
        budget.static_base_tokens +
          budget.dynamic_context_tokens +
          budget.conversation_tokens +
          budget.response_reserve +
          budget.tool_schema_tokens

      assert budget.total_tokens == expected
    end

    test "utilization_pct is a float between 0 and 100" do
      state = base_state()
      budget = Context.token_budget(state)

      assert is_float(budget.utilization_pct)
      assert budget.utilization_pct >= 0.0
      assert budget.utilization_pct <= 100.0
    end

    test "headroom equals max_tokens minus total_tokens" do
      state = base_state()
      budget = Context.token_budget(state)
      assert budget.headroom == budget.max_tokens - budget.total_tokens
    end

    test "blocks is a list of label/priority/tokens maps" do
      state = base_state()
      budget = Context.token_budget(state)

      assert is_list(budget.blocks)

      for block <- budget.blocks do
        assert Map.has_key?(block, :label)
        assert Map.has_key?(block, :priority)
        assert Map.has_key?(block, :tokens)
        assert is_integer(block.tokens)
        assert block.tokens >= 0
      end
    end

    test "blocks list includes known labels" do
      state = base_state()
      budget = Context.token_budget(state)
      labels = Enum.map(budget.blocks, & &1.label)
      # runtime and tool_process are always present
      assert "runtime" in labels
      assert "tool_process" in labels
    end
  end

  # ---------------------------------------------------------------------------
  # estimate_tokens/1 — public function
  # ---------------------------------------------------------------------------

  describe "estimate_tokens/1" do
    test "returns 0 for nil" do
      assert Context.estimate_tokens(nil) == 0
    end

    test "returns 0 for empty string" do
      assert Context.estimate_tokens("") == 0
    end

    test "returns a positive integer for non-empty text" do
      count = Context.estimate_tokens("hello world")
      assert is_integer(count)
      assert count > 0
    end

    test "longer text produces higher token count" do
      short = Context.estimate_tokens("hi")
      long = Context.estimate_tokens(String.duplicate("hello world ", 100))
      assert long > short
    end

    test "returns 0 for non-binary inputs (nil guard)" do
      assert Context.estimate_tokens(nil) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # estimate_tokens_messages/1 — public function
  # ---------------------------------------------------------------------------

  describe "estimate_tokens_messages/1" do
    test "returns 0 for empty list" do
      assert Context.estimate_tokens_messages([]) == 0
    end

    test "counts tokens for a single message" do
      msg = %{role: "user", content: "Hello, how are you?"}
      count = Context.estimate_tokens_messages([msg])
      assert count > 0
    end

    test "accumulates tokens across multiple messages" do
      msgs = [
        %{role: "user", content: "First message with some words"},
        %{role: "assistant", content: "Second message with different words"}
      ]

      count_both = Context.estimate_tokens_messages(msgs)
      count_one = Context.estimate_tokens_messages([hd(msgs)])
      assert count_both > count_one
    end

    test "adds tool call tokens when tool_calls are present" do
      msg_no_tools = %{role: "assistant", content: "plain response"}

      msg_with_tools = %{
        role: "assistant",
        content: "",
        tool_calls: [%{name: "file_read", arguments: "{\"path\": \"/tmp/test.txt\"}"}]
      }

      count_plain = Context.estimate_tokens_messages([msg_no_tools])
      count_tools = Context.estimate_tokens_messages([msg_with_tools])
      assert count_tools > count_plain
    end

    test "handles messages with nil content" do
      msg = %{role: "assistant", content: nil}
      count = Context.estimate_tokens_messages([msg])
      assert is_integer(count)
      assert count >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # Private helper
  # ---------------------------------------------------------------------------

  defp extract_system_text(system_msg) do
    case Map.get(system_msg, :content) do
      content when is_binary(content) ->
        content

      content when is_list(content) ->
        content
        |> Enum.map(&Map.get(&1, :text, ""))
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  # ---------------------------------------------------------------------------
  # First-meet ritual — USER.md name line is the only completion signal
  # ---------------------------------------------------------------------------

  describe "user_known?/1" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "osa-user-known-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "blank template is unknown", %{dir: dir} do
      File.write!(Path.join(dir, "USER.md"), "- **Name:**\n")
      refute Context.user_known?(dir)
    end

    test "missing USER.md is unknown", %{dir: dir} do
      refute Context.user_known?(dir)
    end

    test "filled - **Name:** line is known", %{dir: dir} do
      File.write!(Path.join(dir, "USER.md"), "- **Name:** Roberto\n")
      assert Context.user_known?(dir)
    end

    test "free-form prose without the Name line is unknown", %{dir: dir} do
      File.write!(Path.join(dir, "USER.md"), "They're called Roberto.\n")
      refute Context.user_known?(dir)
    end
  end
end
