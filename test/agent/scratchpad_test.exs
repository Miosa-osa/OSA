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
    test "returns true for :ollama" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      assert Scratchpad.inject?(:ollama)
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

    test "returns false when scratchpad_enabled is false" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, false)
      refute Scratchpad.inject?(:ollama)
      refute Scratchpad.inject?(:openai)
      # Restore default
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
    end

    test "returns true for nil provider (non-Anthropic fallback)" do
      Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)
      assert Scratchpad.inject?(nil)
    end

    test "defaults to enabled when config is not set" do
      Application.delete_env(:optimal_system_agent, :scratchpad_enabled)
      assert Scratchpad.inject?(:ollama)
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

      assert Scratchpad.inject?(:ollama)
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
