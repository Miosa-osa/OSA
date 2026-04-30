defmodule OptimalSystemAgent.Agent.LoopVerificationGateTest do
  @moduledoc """
  Unit tests for the verification gate logic in Loop.

  The verification gate triggers when:
    1. iteration > 2
    2. Session has a task/goal context (user messages with action verbs)
    3. Zero tools executed successfully in the session

  This prevents the agent from returning unverified responses after
  multiple iterations without tool-backed evidence.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop

  # Build a minimal state-like map for needs_verification_gate?/1
  defp gate_state(iteration, messages) do
    %{iteration: iteration, messages: messages}
  end

  # ── Core gate logic ──────────────────────────────────────────────

  describe "needs_verification_gate?/1" do
    test "returns false when iteration <= 2" do
      messages = [
        %{role: "user", content: "fix the bug in router.ex"}
      ]

      refute Loop.needs_verification_gate?(gate_state(0, messages))
      refute Loop.needs_verification_gate?(gate_state(1, messages))
      refute Loop.needs_verification_gate?(gate_state(2, messages))
    end

    test "returns true when iteration > 2, task context present, and zero successful tools" do
      messages = [
        %{role: "user", content: "fix the authentication bug"}
      ]

      assert Loop.needs_verification_gate?(gate_state(3, messages))
      assert Loop.needs_verification_gate?(gate_state(5, messages))
    end

    test "returns false when no task context (no action verbs)" do
      messages = [
        %{role: "user", content: "what is the weather like today?"}
      ]

      refute Loop.needs_verification_gate?(gate_state(3, messages))
    end

    test "returns false when tools executed successfully" do
      messages = [
        %{role: "user", content: "fix the bug in router.ex"},
        %{role: "tool", content: "contents of router.ex: defmodule Router do..."}
      ]

      refute Loop.needs_verification_gate?(gate_state(3, messages))
    end

    test "returns true when all tool results are errors" do
      messages = [
        %{role: "user", content: "fix the bug in router.ex"},
        %{role: "tool", content: "Error: file not found"},
        %{role: "tool", content: "Error: permission denied"}
      ]

      assert Loop.needs_verification_gate?(gate_state(4, messages))
    end

    test "returns true when all tool results are blocked" do
      messages = [
        %{role: "user", content: "run the deployment script"},
        %{role: "tool", content: "Blocked: dangerous command"}
      ]

      assert Loop.needs_verification_gate?(gate_state(3, messages))
    end

    test "returns false when at least one tool succeeded among failures" do
      messages = [
        %{role: "user", content: "fix the bug in router.ex"},
        %{role: "tool", content: "Error: file not found"},
        %{role: "tool", content: "defmodule Router do\n  # contents here\nend"}
      ]

      refute Loop.needs_verification_gate?(gate_state(3, messages))
    end

    test "returns false when no tool messages at all but no task context" do
      messages = [
        %{role: "user", content: "hello there"}
      ]

      refute Loop.needs_verification_gate?(gate_state(5, messages))
    end

    test "returns true with no tool messages but task context present" do
      # Zero tool messages means zero_successful_tools? returns true
      messages = [
        %{role: "user", content: "create a new module for authentication"}
      ]

      assert Loop.needs_verification_gate?(gate_state(3, messages))
    end
  end

  # ── Task context detection ──────────────────────────────────────

  describe "task context detection via action verbs" do
    test "detects common action verbs" do
      action_words =
        ~w(fix create build implement add update change write deploy test debug refactor delete remove find search check run install configure)

      for word <- action_words do
        messages = [%{role: "user", content: "#{word} the module"}]
        state = gate_state(3, messages)

        assert Loop.needs_verification_gate?(state),
               "Expected verification gate to trigger for action verb '#{word}'"
      end
    end

    test "does not trigger on non-action messages" do
      non_action = [
        "what is this?",
        "how does it work?",
        "explain the architecture",
        "hello",
        "thanks",
        "good morning"
      ]

      for msg <- non_action do
        messages = [%{role: "user", content: msg}]
        state = gate_state(3, messages)

        refute Loop.needs_verification_gate?(state),
               "Expected verification gate NOT to trigger for '#{msg}'"
      end
    end

    test "ignores assistant and system messages for task context" do
      messages = [
        %{role: "system", content: "fix everything"},
        %{role: "assistant", content: "I will create a new module"},
        %{role: "user", content: "sounds good"}
      ]

      refute Loop.needs_verification_gate?(gate_state(3, messages))
    end
  end
end
