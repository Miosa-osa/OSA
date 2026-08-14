defmodule OptimalSystemAgent.Agent.ScratchpadTest do
  @moduledoc """
  Tests for provider-agnostic scratchpad/thinking support.

  Verifies:
    - <think> tag extraction from response text
    - Thinking is removed from displayed response
    - Scratchpad instruction injection for non-Anthropic providers
    - Anthropic uses native thinking (no injection)
    - Thinking events are emitted via Bus
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Scratchpad

  # ---------------------------------------------------------------------------
  # inject?/1 — provider-based injection decision
  # ---------------------------------------------------------------------------

  describe "inject?/1" do
    # A LOCALLY served, non-reasoning tag: `Ollama.reasoning_decision/2` answers
    # `{nil, :unsupported}`, so nothing native is on the wire and the scaffold is
    # this turn's only reasoning space.
    test "returns true for :ollama on a model with no native reasoning" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      assert Scratchpad.inject?(%{provider: :ollama, model: "llama3.1:8b"})
    end

    # The mirror-image defect. `glm-5.2:cloud` is a CLOUD tag, and Ollama drives
    # cloud tags with `think: true` (`{true, :cloud_default}`) — so under the old
    # `provider != :anthropic` gate this turn got a native reasoning channel AND
    # was told to hand-roll `<think>` tags around its answer. Asking the real
    # question removes the second copy.
    test "returns false for :ollama on a cloud tag that already reasons natively" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      refute Scratchpad.inject?(%{provider: :ollama, model: "glm-5.2:cloud"})
    end

    test "returns true for :openai" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      assert Scratchpad.inject?(:openai)
    end

    test "returns true for :groq" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      assert Scratchpad.inject?(:groq)
    end

    test "returns true for :openrouter" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      assert Scratchpad.inject?(:openrouter)
    end

    test "returns false for :anthropic (uses native extended thinking)" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      refute Scratchpad.inject?(:anthropic)
    end

    # `anthropic/*` served through OpenRouter. Intuition says "it's a Claude, it
    # has native thinking, don't scaffold it" — and that is wrong: OSA sends this
    # route no `thinking` and no `reasoning_effort` (see
    # `OpenAICompat.maybe_add_reasoning/3`, which excludes Anthropic ids), so
    # suppressing the scaffold would leave the turn with nothing. Asserted so a
    # future "just check the model name" shortcut fails loudly here.
    test "returns true for anthropic/* via OpenRouter — it has no native thinking today" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

      assert Scratchpad.inject?(%{provider: :openrouter, model: "anthropic/claude-opus-5"})
    end

    # ...and it is not injected TWICE. One scaffold, one decision, one source.
    test "the scaffold is a single decision, not a per-call accumulation" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      state = %{provider: :openrouter, model: "anthropic/claude-opus-5"}

      assert {true, :no_native_thinking} = Scratchpad.decision(state)
      assert Scratchpad.decision(state) == Scratchpad.decision(state)

      instruction = Scratchpad.instruction()
      assert length(String.split(instruction, "## Private Reasoning")) == 2
    end

    # Prefix stability: the scaffold block feeds a CACHED system prompt, so for a
    # fixed model + config the answer must not wobble between calls within a
    # session. 92.8% cache hit rate depends on it.
    test "the decision is constant for a fixed model and config" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

      for state <- [
            %{provider: :anthropic, model: "claude-opus-5"},
            %{provider: :ollama, model: "llama3.1:8b"},
            %{provider: :openrouter, model: "anthropic/claude-opus-5"}
          ] do
        first = Scratchpad.decision(state)
        assert Enum.all?(1..25, fn _ -> Scratchpad.decision(state) == first end)
      end
    end

    test "returns false when scratchpad_enabled is false" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, false)
      refute Scratchpad.inject?(%{provider: :ollama, model: "llama3.1:8b"})
      refute Scratchpad.inject?(:openai)
      # Restore default
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
    end

    test "a nil provider falls back to the configured default" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      # Same answer as naming that default explicitly — the fallback resolves the
      # provider, it does not bypass the question.
      assert Scratchpad.decision(nil) ==
               Scratchpad.decision(
                 Application.get_env(:optimal_system_agent, :default_provider, :ollama)
               )
    end

    test "defaults to enabled when config is not set" do
      Application.delete_env(:optimal_system_agent, :scratchpad_enabled)
      assert Scratchpad.inject?(%{provider: :ollama, model: "llama3.1:8b"})
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
    end
  end

  # ---------------------------------------------------------------------------
  # instruction/0 — scratchpad system prompt
  # ---------------------------------------------------------------------------

  describe "instruction/0" do
    test "returns a non-empty string" do
      instruction = Scratchpad.instruction()
      assert is_binary(instruction)
      assert String.length(instruction) > 50
    end

    test "contains <think> tag reference" do
      instruction = Scratchpad.instruction()
      assert String.contains?(instruction, "<think>")
      assert String.contains?(instruction, "</think>")
    end

    test "mentions private reasoning" do
      instruction = Scratchpad.instruction()

      assert String.contains?(instruction, "Private Reasoning") or
               String.contains?(instruction, "reasoning")
    end

    test "mentions content is not shown to user" do
      instruction = Scratchpad.instruction()
      assert String.contains?(instruction, "NOT shown to the user")
    end
  end

  # ---------------------------------------------------------------------------
  # extract/1 — <think> block extraction
  # ---------------------------------------------------------------------------

  describe "extract/1" do
    test "extracts single <think> block" do
      text = "<think>I should check the file first</think>Here is the result."
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "Here is the result."
      assert thinking == ["I should check the file first"]
    end

    test "extracts multiple <think> blocks" do
      text = """
      <think>First, analyze the request.</think>
      Starting work.
      <think>Now I need to check edge cases.</think>
      Done with analysis.
      """

      {clean, thinking} = Scratchpad.extract(text)

      assert length(thinking) == 2
      assert "First, analyze the request." in thinking
      assert "Now I need to check edge cases." in thinking
      assert not String.contains?(clean, "<think>")
      assert not String.contains?(clean, "</think>")
      assert String.contains?(clean, "Starting work.")
      assert String.contains?(clean, "Done with analysis.")
    end

    test "handles multiline thinking content" do
      text = """
      <think>
      Step 1: Read the file
      Step 2: Find the bug
      Step 3: Fix it
      </think>
      I found and fixed the bug.
      """

      {clean, thinking} = Scratchpad.extract(text)

      assert length(thinking) == 1
      assert String.contains?(hd(thinking), "Step 1: Read the file")
      assert String.contains?(hd(thinking), "Step 3: Fix it")
      assert clean == "I found and fixed the bug."
    end

    test "returns original text when no <think> blocks present" do
      text = "Just a normal response without any thinking."
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == text
      assert thinking == []
    end

    test "handles nil input" do
      {clean, thinking} = Scratchpad.extract(nil)
      assert clean == ""
      assert thinking == []
    end

    test "handles empty string input" do
      {clean, thinking} = Scratchpad.extract("")
      assert clean == ""
      assert thinking == []
    end

    test "handles empty <think> blocks" do
      text = "<think></think>Response here."
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "Response here."
      assert thinking == []
    end

    test "handles whitespace-only <think> blocks" do
      text = "<think>   \n  </think>Response here."
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "Response here."
      assert thinking == []
    end

    test "preserves response formatting" do
      text = """
      <think>reasoning</think>
      ## Header

      - Item 1
      - Item 2

      ```elixir
      def hello, do: "world"
      ```
      """

      {clean, _thinking} = Scratchpad.extract(text)

      assert String.contains?(clean, "## Header")
      assert String.contains?(clean, "- Item 1")
      assert String.contains?(clean, "def hello")
    end

    test "collapses excessive newlines after extraction" do
      text = "<think>reasoning</think>\n\n\n\nResponse."
      {clean, _thinking} = Scratchpad.extract(text)

      # Should not have more than 2 consecutive newlines
      refute String.contains?(clean, "\n\n\n")
    end

    test "handles <think> at end of response" do
      text = "Here is my response.<think>Post-hoc reflection</think>"
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "Here is my response."
      assert thinking == ["Post-hoc reflection"]
    end

    test "handles response that is ONLY a <think> block" do
      text = "<think>The user wants me to just think about this</think>"
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == ""
      assert thinking == ["The user wants me to just think about this"]
    end
  end

  # ---------------------------------------------------------------------------
  # process_response/2 — full pipeline (extract + emit events)
  # ---------------------------------------------------------------------------

  describe "process_response/2" do
    test "returns clean text with thinking removed" do
      text = "<think>reasoning here</think>Clean output."
      result = Scratchpad.process_response(text, "test-session")

      assert result == "Clean output."
    end

    test "returns original text when no thinking present" do
      text = "Just a normal response."
      result = Scratchpad.process_response(text, "test-session")

      assert result == "Just a normal response."
    end

    test "handles nil text" do
      result = Scratchpad.process_response(nil, "test-session")
      assert result == ""
    end

    test "handles empty text" do
      result = Scratchpad.process_response("", "test-session")
      assert result == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: Context injection decision
  # ---------------------------------------------------------------------------

  describe "provider-based context injection" do
    test "Anthropic provider should NOT get scratchpad instruction injected" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

      # Anthropic uses native extended thinking
      refute Scratchpad.inject?(:anthropic)
    end

    test "Ollama provider SHOULD get scratchpad instruction injected" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

      assert Scratchpad.inject?(%{provider: :ollama, model: "llama3.1:8b"})
      instruction = Scratchpad.instruction()
      assert String.contains?(instruction, "<think>")
    end

    test "OpenAI provider SHOULD get scratchpad instruction injected" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

      assert Scratchpad.inject?(:openai)
    end

    test "Google provider SHOULD get scratchpad instruction injected" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

      assert Scratchpad.inject?(:google)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases and robustness
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "nested angle brackets inside think block" do
      text = "<think>Check if x > 5 and y < 10</think>Result: x is 7."
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "Result: x is 7."
      assert thinking == ["Check if x > 5 and y < 10"]
    end

    test "code blocks inside think block" do
      text = """
      <think>
      The function looks like:
      ```elixir
      def foo(x), do: x + 1
      ```
      This needs fixing.
      </think>
      I fixed the function.
      """

      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "I fixed the function."
      assert length(thinking) == 1
      assert String.contains?(hd(thinking), "def foo(x)")
    end

    test "literal <think> in code blocks is still extracted" do
      # This is a known trade-off: if an LLM puts <think> literally in code,
      # it will be extracted. Acceptable because the instruction tells the LLM
      # to use <think> only for private reasoning.
      text = "<think>planning</think>Use `<think>` for reasoning."
      {clean, thinking} = Scratchpad.extract(text)

      assert thinking == ["planning"]
      assert String.contains?(clean, "Use `<think>` for reasoning.")
    end

    test "very long thinking content is handled" do
      long_thinking = String.duplicate("reasoning step. ", 1000)
      text = "<think>#{long_thinking}</think>Short answer."
      {clean, thinking} = Scratchpad.extract(text)

      assert clean == "Short answer."
      assert length(thinking) == 1
      assert String.length(hd(thinking)) > 10_000
    end
  end
end
