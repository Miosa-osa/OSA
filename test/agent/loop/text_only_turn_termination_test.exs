defmodule OptimalSystemAgent.Agent.Loop.TextOnlyTurnTerminationTest do
  @moduledoc """
  A text-only answer ends the turn.

  When the model returns visible text and calls no tools, that IS the answer.
  Codex, grok-build and Claude Code all end the turn there. OSA did not: three
  heuristics in `ReactLoop.handle_result/3`'s no-tool-call branch re-entered
  `run/1` on the strength of *how the prose was worded*, each costing a full
  model round-trip against the whole context.

    * `Guardrails.wants_to_continue?/1` — a regex for "Let me check…" / "I'll
      look at…". An explanatory answer that merely *describes* what one would
      do trips it. Up to 2 extra round-trips.
    * `Guardrails.code_in_text?/1` — a fenced code block of 5+ lines. Answering
      "how do I write this function?" with the function trips it. 1 more.
    * `Guardrails.needs_verification_gate?/1` — iteration > 2, an action verb
      anywhere in the user's message, and no successful tool this session. None
      of its three inputs change when it fires, so it re-fires every time the
      model answers in text, and it carries no counter of its own.

  The last one is the sharp edge: because it resets `auto_continues` to 2 while
  `code_in_text?` accepts anything under 3, the two clauses ping-pong — gate
  drops the counter to 2, code-in-text raises it to 3, gate drops it again —
  and the turn only stops at the global iteration cap.

  These tests count real provider round-trips for one text-only turn.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  # Trips `wants_to_continue?` ("let me check") — and is a perfectly ordinary
  # sentence in an explanatory answer.
  @intent_text "Let me check the configuration: the value lives in config/runtime.exs " <>
                 "and is read at boot, so changing it needs a restart."

  # Trips `code_in_text?` — a fenced block of 5+ lines, i.e. the correct answer
  # to "show me what this function should look like".
  @code_text """
  Here is what that function should look like:

  ```elixir
  def add(a, b) do
    a + b
  end

  def sub(a, b) do
    a - b
  end
  ```
  """

  # An action verb ("check") gives `needs_verification_gate?` its task context.
  @user_message "check how the retry budget is configured and explain it to me"

  setup do
    prev = %{
      provider: Application.get_env(:optimal_system_agent, :default_provider),
      text: Application.get_env(:optimal_system_agent, :mock_provider_final_text),
      max_iter: Application.get_env(:optimal_system_agent, :max_iterations),
      continue: Application.get_env(:optimal_system_agent, :continue_on_text_only)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    # A low cap so the unbounded ping-pong terminates in bounded test time; the
    # measured number is still the honest "this turn does not stop on its own".
    Application.put_env(:optimal_system_agent, :max_iterations, 12)

    on_exit(fn ->
      restore(:default_provider, prev.provider)
      restore(:mock_provider_final_text, prev.text)
      restore(:max_iterations, prev.max_iter)
      restore(:continue_on_text_only, prev.continue)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp sid, do: "text-only-turn-#{System.unique_integer([:positive])}"

  # A plain map (not the struct) because the loop `Map.put/3`s keys the struct
  # does not declare (`:target_continues`, `:just_compacted`, …).
  defp base_state(user_message) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: sid(),
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      messages: [%{role: "user", content: user_message}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  # Run one turn against a provider pinned to `text` and report how many
  # round-trips it cost.
  defp round_trips_for(text, user_message \\ @user_message) do
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, text)
    MockProvider.reset_round_trips()

    {_response, _state} = ReactLoop.run(base_state(user_message))

    MockProvider.round_trips()
  end

  describe "a text-only answer costs exactly one round-trip" do
    test "prose that reads as narrated intent is still a final answer" do
      n = round_trips_for(@intent_text)

      assert n == 1,
             "a text-only answer must end the turn; " <>
               "'Let me check…' phrasing cost #{n} model round-trips"
    end

    test "an answer containing a code block is still a final answer" do
      n = round_trips_for(@code_text)

      assert n == 1,
             "showing code in the answer must not re-enter the loop; " <>
               "cost #{n} model round-trips"
    end

    test "a plain answer to a task-context question does not trip the verification gate" do
      n = round_trips_for("The retry budget is 3 attempts with exponential backoff.")

      assert n == 1,
             "a plain text answer cost #{n} model round-trips"
    end

    test "the worst case does not run to the iteration cap" do
      # Intent phrasing AND a code block AND task context — every heuristic at
      # once. Before the fix this ping-ponged between the code-in-text nudge and
      # the verification gate until `max_iterations`.
      n = round_trips_for(@intent_text <> "\n\n" <> @code_text)

      assert n == 1,
             "the combined case cost #{n} model round-trips " <>
               "(the iteration cap for this test is 12)"
    end
  end

  describe "continuation remains available as an explicit opt-in" do
    test "continue_on_text_only: true restores the old nudging behaviour" do
      Application.put_env(:optimal_system_agent, :continue_on_text_only, true)

      n = round_trips_for(@intent_text)

      assert n > 1,
             "the escape hatch must still be able to drive the loop past a " <>
               "text-only answer; cost #{n} round-trips"
    end

    test "the per-session flag beats the app-env default in both directions" do
      Application.put_env(:optimal_system_agent, :continue_on_text_only, true)
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, @intent_text)

      MockProvider.reset_round_trips()
      state = Map.put(base_state(@user_message), :continue_on_text_only, false)
      {_r, _s} = ReactLoop.run(state)

      assert MockProvider.round_trips() == 1,
             "a session that opts OUT must end the turn even when the app env opts in"
    end

    test "even opted in, the zero-tool gate cannot ping-pong to the iteration cap" do
      # `needs_verification_gate?/1` reset `auto_continues` to 2 while the
      # code-in-text clause accepted anything under 3, so the two traded the
      # counter back and forth and the turn only stopped at `max_iterations`
      # — measured at cap+1 round-trips (13 at a cap of 12, 31 at a cap of 30).
      # `@max_zero_tool_gate_prompts` makes the cost cap-independent.
      Application.put_env(:optimal_system_agent, :continue_on_text_only, true)

      at_12 = round_trips_for(@code_text)

      Application.put_env(:optimal_system_agent, :max_iterations, 60)
      at_60 = round_trips_for(@code_text)

      assert at_12 == at_60,
             "the cost of a text-only answer must not scale with the iteration cap " <>
               "(#{at_12} at cap 12 vs #{at_60} at cap 60)"

      assert at_12 <= 6,
             "the bounded worst case regressed to #{at_12} round-trips"
    end
  end
end
