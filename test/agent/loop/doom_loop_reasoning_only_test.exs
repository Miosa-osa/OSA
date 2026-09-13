defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnlyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.DoomLoop
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Resample

  # A session that has SUCCESSFULLY used a tool — i.e. a task session, not a
  # conversation.
  #
  # This premise used to be implicit (`messages: []`), and implicit was wrong.
  # The guard now refuses to halt a session that has only talked, because zero
  # tool calls in a conversation is correct behaviour rather than a spin — see
  # `ReasoningOnly.suppressed/1` and the live report it cites. A test that wants
  # to exercise the HALT must therefore say that this is a session where tool
  # use was warranted.
  defp base_state do
    %{
      session_id: "test-reasoning-only",
      total_tool_calls: 0,
      recent_failure_signatures: [],
      messages: [
        %{role: "user", content: "fix the parser"},
        %{role: "tool", tool_call_id: "seed", content: "ok, read 40 lines"}
      ]
    }
  end

  # The same session before any tool has run: a pure conversation.
  defp conversation_state do
    %{
      session_id: "test-reasoning-only-conversation",
      total_tool_calls: 0,
      recent_failure_signatures: [],
      messages: [%{role: "user", content: "ok how about now"}]
    }
  end

  describe "check/3 — reasoning-only spin (no tool calls)" do
    test "does not trip on the first couple of empty-tool-call turns" do
      assert {:ok, state} = DoomLoop.check([], [], base_state())
      assert state.reasoning_only_streak == 1

      assert {:ok, state} = DoomLoop.check([], [], state)
      assert state.reasoning_only_streak == 2
    end

    test "trips at the configured threshold (default 3) and halts" do
      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)

      assert {:halt, msg, halted_state} = DoomLoop.check([], [], state)
      assert msg =~ "reasoning-only"
      assert halted_state.reasoning_only_streak == 0
    end

    test "a tool call in between resets the streak" do
      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)

      tc = %{id: "c1", name: "file_read", arguments: %{"path" => "x"}}
      result = {%{role: "tool", tool_call_id: "c1", content: "ok"}, "ok"}

      assert {:ok, state} = DoomLoop.check([{tc, result}], [tc], state)
      assert state.reasoning_only_streak == 0

      # Back to reasoning-only afterward starts counting from zero again.
      assert {:ok, state} = DoomLoop.check([], [], state)
      assert state.reasoning_only_streak == 1
    end
  end

  describe "check/3 — turn-errored (caller-flagged) spin" do
    test "state.turn_errored counts toward the streak even with an attempted tool call" do
      tc = %{id: "c1", name: "shell_execute", arguments: %{"command" => "x"}}
      result = {%{role: "tool", tool_call_id: "c1", content: "Error: boom"}, "Error: boom"}

      state = Map.put(base_state(), :turn_errored, true)
      {:ok, state} = DoomLoop.check([{tc, result}], [tc], state)
      assert state.reasoning_only_streak == 1

      state = Map.put(state, :turn_errored, true)
      {:ok, state} = DoomLoop.check([{tc, result}], [tc], state)
      assert state.reasoning_only_streak == 2

      state = Map.put(state, :turn_errored, true)
      assert {:halt, msg, _state} = DoomLoop.check([{tc, result}], [tc], state)
      assert msg =~ "kept erroring"
    end

    test "the turn_errored flag is one-shot — cleared after each check even without tripping" do
      state = Map.put(base_state(), :turn_errored, true)
      {:ok, state} = DoomLoop.check([], [], state)
      refute state.turn_errored
    end
  end

  describe "hand-off to the existing Resample remedy" do
    test "a reasoning-only halt is resampled exactly like any other doom-loop halt" do
      put_resample_config(enabled: true, max_retries: 2, backoff_ms: 0)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :doom_loop_resample) end)

      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)
      assert {:halt, doom_message, halted_state} = DoomLoop.check([], [], state)

      snapshot = Map.put(base_state(), :doom_resamples, 0)
      test_pid = self()

      run_fun = fn retry_state ->
        send(test_pid, {:resampled, retry_state})
        {"recovered", retry_state}
      end

      assert {"recovered", final} = Resample.handle(doom_message, halted_state, snapshot, run_fun)
      assert_received {:resampled, _retry_state}
      assert final.doom_resamples == 1
    end
  end

  defp put_resample_config(kw),
    do: Application.put_env(:optimal_system_agent, :doom_loop_resample, kw)

  # ── A conversation is not a spin ────────────────────────────────────
  #
  # LIVE REPORT: a user typed `ok how about now` into the TUI and OSA's entire
  # reply was this guard's advice text — "Stopped: 3 consecutive generations
  # produced no tool calls ... call a concrete tool to move forward" — which is
  # addressed to the model, not to them.
  describe "conversational turns are not spins" do
    test "a session that has only talked never halts, however long the streak" do
      state = conversation_state()

      # Well past the threshold of 3.
      state =
        Enum.reduce(1..6, state, fn _, acc ->
          assert {:ok, next} = DoomLoop.check([], [], acc)
          next
        end)

      # It still COUNTS — suppression is not blindness, and the streak is what
      # an operator sees in the event stream.
      assert state.reasoning_only_streak >= 3
    end

    test "the guard's advice can never become the reply for a conversation" do
      state = conversation_state()

      Enum.reduce(1..6, state, fn _, acc ->
        result = DoomLoop.check([], [], acc)
        # The ONLY shape that can carry text out to the user is `{:halt, msg, _}`.
        # If it never occurs, the guard's text structurally cannot be the answer.
        refute match?({:halt, _, _}, result)
        {:ok, next} = result
        next
      end)
    end

    test "a task session (tools already used) still halts — the guard is not disabled" do
      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)

      assert {:halt, msg, _} = DoomLoop.check([], [], state)
      assert msg =~ "reasoning-only"
    end
  end

  # ── An EMPTY generation is a spin even in a conversation / attended session ──
  #
  # LIVE REPORT: grok-4.6 with thinking on "thinks for a bit then just stops" —
  # it returns NO visible content and no tool call. In an attended TUI the
  # conversational/attended suppression above kept the halt from firing, so it
  # nudge-looped forever. A conversation is the model TALKING; a generation with
  # no content is not one, and `generation_empty` (set by the caller from its
  # `visible_empty?`) says so.
  describe "an empty generation bypasses conversational suppression" do
    test "empty content in a conversation session still halts at the threshold" do
      empty = fn s -> Map.put(s, :generation_empty, true) end

      state = conversation_state()
      {:ok, state} = DoomLoop.check([], [], empty.(state))
      {:ok, state} = DoomLoop.check([], [], empty.(state))

      assert {:halt, msg, _} = DoomLoop.check([], [], empty.(state))
      assert msg =~ "reasoning-only"
    end

    test "generation_empty is one-shot — cleared after each check" do
      state = Map.put(conversation_state(), :generation_empty, true)
      {:ok, state} = DoomLoop.check([], [], state)
      refute Map.get(state, :generation_empty, false)
    end

    test "a content-ful conversational turn (flag unset) is still NOT halted" do
      # The regression guard: only an EMPTY generation bypasses suppression. A
      # normal talking turn (caller leaves the flag unset) stays protected.
      state = conversation_state()

      Enum.reduce(1..6, state, fn _, acc ->
        refute match?({:halt, _, _}, DoomLoop.check([], [], acc))
        {:ok, next} = DoomLoop.check([], [], acc)
        next
      end)
    end
  end

  describe "provenance — guard text is never the model's answer" do
    alias OptimalSystemAgent.Agent.Loop.TerminalSource

    test "a resampled-out doom halt is marked as guard-authored" do
      state = base_state()
      {:ok, state} = DoomLoop.check([], [], state)
      {:ok, state} = DoomLoop.check([], [], state)
      {:halt, msg, halted} = DoomLoop.check([], [], state)

      # Resample with the budget disabled returns the halt tuple straight
      # through — this is the exact path that delivered guard text as the answer.
      {out, out_state} = Resample.handle(msg, halted, halted, fn s -> {"re-rolled", s} end)

      if out == msg do
        assert TerminalSource.of(out_state) == :guard
        refute TerminalSource.model?(out_state)
        # And that is what puts "system" rather than "agent" on the wire.
        assert TerminalSource.response_type(out_state) == "system"
      end
    end

    test "an unmarked state is treated as the model — the healthy path is unchanged" do
      assert TerminalSource.of(%{}) == :model
      assert TerminalSource.response_type(%{}) == "agent"
      assert TerminalSource.label(%{}) == nil
    end

    test "the mark is cleared, so one guard halt cannot poison later turns" do
      marked = TerminalSource.mark(%{}, :guard)
      assert TerminalSource.of(marked) == :guard
      assert TerminalSource.of(TerminalSource.reset(marked)) == :model
    end
  end
end
