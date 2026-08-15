defmodule OptimalSystemAgent.Agent.Loop.TerminalSourceTest do
  @moduledoc """
  Pins the defect: control-flow text must never be delivered as the model's
  answer.

  ## The report

  A user typed a short conversational message into the TUI and OSA's entire
  reply, under the `◈ OSA` header, was the doom-loop guard's internal advice:

      ❯ You
        ok how about now

      ◈ OSA
        Stopped: 3 consecutive generations produced no tool calls without making
        progress (reasoning-only spin). Reconsider the goal, call a concrete tool
        to move forward, or decompose the task into smaller steps.

  Note who that text is addressed to. "Reconsider the goal, call a concrete
  tool" is an instruction to the MODEL. It was shown to the USER, as the
  assistant's reply, which is wrong twice over: it is not an answer, and it is
  not even written to its reader.

  The same class had already been seen on the `schemelike` benchmark instance,
  where the three "generations that produced no tool calls" were in fact three
  provider TRUNCATIONS — the guard was reporting a cut-off model as a stalled
  one, and then its complaint became the graded answer.

  ## What is pinned here

  `ReactLoop.run/1` returns `{String.t(), map()}` — one untyped string channel
  shared by the model's answer and every guard, cap, pause and error message. It
  was structurally impossible for `Loop.run_and_reply/1` to tell them apart, so
  it labelled all of them `response_type: "agent"` and appended all of them to
  the transcript as `role: "assistant"`.

  These tests pin the provenance mechanism that fixes that.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.TerminalSource

  describe "the default is the model, and it is safe" do
    test "an unmarked state is the model's own answer" do
      assert TerminalSource.of(%{}) == :model
      assert TerminalSource.model?(%{})
    end

    test "the healthy path is bit-for-bit what every existing consumer receives" do
      # If this changes, every SSE client, the CLI, the TUI and the benchmark
      # harness change with it. It must not.
      assert TerminalSource.response_type(%{}) == "agent"
      assert TerminalSource.label(%{}) == nil
    end

    test "a garbage value degrades to the model rather than to chrome" do
      assert TerminalSource.of(%{terminal_source: :nonsense}) == :model
      assert TerminalSource.of(%{terminal_source: "guard"}) == :model
      assert TerminalSource.of(%{terminal_source: nil}) == :model
    end
  end

  describe "guard, control and error text is marked" do
    test "each non-model source is carried on the state" do
      for source <- [:guard, :control, :error] do
        assert TerminalSource.of(TerminalSource.mark(%{}, source)) == source
        refute TerminalSource.model?(TerminalSource.mark(%{}, source))
      end
    end

    test "every non-model source goes on the wire as a system message" do
      # This is the assertion that makes the reported rendering impossible: the
      # TUI routes anything that is not "agent"/"plan"/"genre" to
      # `add_system_message`, which has no agent header and no agent glyph.
      for source <- [:guard, :control, :error] do
        state = TerminalSource.mark(%{}, source)

        assert TerminalSource.response_type(state) == "system",
               "#{source} must not be delivered as the model's answer"
      end
    end

    test "each source carries a label a client can show without parsing the text" do
      assert TerminalSource.label(TerminalSource.mark(%{}, :guard)) == "loop guard"
      assert TerminalSource.label(TerminalSource.mark(%{}, :control)) == "stopped"
      assert TerminalSource.label(TerminalSource.mark(%{}, :error)) == "error"
    end

    test "halt/3 marks and returns in one call, so the mark cannot be forgotten" do
      assert {"some guard text", state} =
               TerminalSource.halt("some guard text", %{a: 1}, :guard)

      # The tuple shape the halt sites already return is preserved exactly, so
      # this is a drop-in at every call site.
      assert state.a == 1
      assert TerminalSource.of(state) == :guard
    end
  end

  describe "the mark does not leak across turns" do
    test "reset/1 clears it" do
      marked = TerminalSource.mark(%{}, :guard)
      assert TerminalSource.of(TerminalSource.reset(marked)) == :model
    end

    test "a fresh user turn wipes a previous turn's guard halt" do
      # This is what makes opt-in marking safe. Without the reset, ONE guard
      # halt would make every later answer in the session render as system
      # chrome — a regression on every healthy turn.
      state =
        TerminalSource.mark(
          %{
            session_id: "s",
            iteration: 3,
            overflow_retries: 0,
            auto_continues: 0,
            status: :done,
            exploration_done: true,
            recent_failure_signatures: [],
            doom_recovery_count: 0,
            messages: []
          },
          :guard
        )

      fresh = OptimalSystemAgent.Agent.Loop.TurnPipeline.reset_per_turn_fields(state)

      assert TerminalSource.of(fresh) == :model
      assert TerminalSource.response_type(fresh) == "agent"
    end
  end

  describe "the exact reported string cannot be a model answer" do
    @reported "Stopped: 3 consecutive generations produced no tool calls without making " <>
                "progress (reasoning-only spin). Reconsider the goal, call a concrete tool " <>
                "to move forward, or decompose the task into smaller steps."

    test "when the guard emits it, the wire says system — not agent" do
      {text, state} = TerminalSource.halt(@reported, %{session_id: "s"}, :guard)

      # The text is deliberately unchanged — provenance belongs in a field, not
      # in a prefix that string-matching has to re-detect across a language
      # boundary.
      assert text == @reported
      assert TerminalSource.response_type(state) == "system"
      refute TerminalSource.model?(state)
    end
  end
end
