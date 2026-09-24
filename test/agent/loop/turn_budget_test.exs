defmodule OptimalSystemAgent.Agent.Loop.TurnBudgetTest do
  @moduledoc """
  `Agent.Loop.TurnBudget` — the per-step pacing note's tracking and formatting.

  What the model actually SEES each step is the string `note/2` returns; these
  tests assert on that exact string so a format regression is caught here
  rather than by a human squinting at a transcript.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.TurnBudget

  setup do
    for key <- [:budget_note_enabled, :budget_turn_tokens, :budget_warn_steps, :budget_warn_frac] do
      Application.delete_env(:optimal_system_agent, key)
    end

    :ok
  end

  defp sid, do: "turn-budget-#{System.unique_integer([:positive, :monotonic])}"

  describe "start_turn/1 + record/2 + snapshot/1" do
    test "a fresh session starts at zero output tokens" do
      s = sid()
      TurnBudget.start_turn(s)
      assert TurnBudget.snapshot(s).output_tokens == 0
    end

    test "record/2 accumulates output tokens across multiple calls" do
      s = sid()
      TurnBudget.start_turn(s)
      TurnBudget.record(s, %{output_tokens: 100})
      TurnBudget.record(s, %{output_tokens: 250})
      assert TurnBudget.snapshot(s).output_tokens == 350
    end

    test "record/2 tolerates string-keyed usage maps" do
      s = sid()
      TurnBudget.start_turn(s)
      TurnBudget.record(s, %{"output_tokens" => 42})
      assert TurnBudget.snapshot(s).output_tokens == 42
    end

    test "start_turn/1 resets the counter for a NEW top-level turn" do
      s = sid()
      TurnBudget.start_turn(s)
      TurnBudget.record(s, %{output_tokens: 999})
      TurnBudget.start_turn(s)
      assert TurnBudget.snapshot(s).output_tokens == 0
    end

    test "record/2 before any start_turn/1 still tracks (defensive)" do
      s = sid()
      TurnBudget.record(s, %{output_tokens: 10})
      assert TurnBudget.snapshot(s).output_tokens == 10
    end
  end

  describe "configuration defaults" do
    test "enabled?/0 defaults to true" do
      assert TurnBudget.enabled?()
    end

    test "token_budget/0 scales with effort level" do
      assert TurnBudget.default_token_budget(:fast) < TurnBudget.default_token_budget(:medium)
      assert TurnBudget.default_token_budget(:medium) < TurnBudget.default_token_budget(:high)
      assert TurnBudget.default_token_budget(:high) < TurnBudget.default_token_budget(:xhigh)
      assert TurnBudget.default_token_budget(:xhigh) < TurnBudget.default_token_budget(:ultra)
    end

    test "app-env config overrides the effort-scaled default" do
      Application.put_env(:optimal_system_agent, :budget_turn_tokens, 12_345)
      assert TurnBudget.token_budget() == 12_345
    end

    test "app-env can disable the note entirely" do
      Application.put_env(:optimal_system_agent, :budget_note_enabled, false)
      refute TurnBudget.enabled?()
    end
  end

  describe "note/2 — the exact string the model sees" do
    test "shows step, tokens, and elapsed time in a compact single line" do
      s = sid()
      TurnBudget.start_turn(s)
      TurnBudget.record(s, %{output_tokens: 1_200})
      Application.put_env(:optimal_system_agent, :budget_turn_tokens, 150_000)

      note = TurnBudget.note(%{session_id: s, iteration: 2}, 100)

      assert note == "[Budget: step 3/100 (98 left) | tokens ~1k/150k (148k left) | elapsed 0s]"
    end

    test "returns nil when disabled" do
      s = sid()
      TurnBudget.start_turn(s)
      Application.put_env(:optimal_system_agent, :budget_note_enabled, false)
      assert TurnBudget.note(%{session_id: s, iteration: 0}, 10) == nil
    end

    test "switches to wrap-up wording when steps remaining are low" do
      s = sid()
      TurnBudget.start_turn(s)
      Application.put_env(:optimal_system_agent, :budget_turn_tokens, 150_000)
      Application.put_env(:optimal_system_agent, :budget_warn_steps, 10)

      note = TurnBudget.note(%{session_id: s, iteration: 94}, 100)

      assert note =~ "BUDGET NEARLY SPENT"
      assert note =~ "Summarize state and next steps"
      assert note =~ "step 95/100 (6 left)"
    end

    test "switches to wrap-up wording when the token budget is nearly spent" do
      s = sid()
      TurnBudget.start_turn(s)
      TurnBudget.record(s, %{output_tokens: 140_000})
      Application.put_env(:optimal_system_agent, :budget_turn_tokens, 150_000)
      Application.put_env(:optimal_system_agent, :budget_warn_frac, 0.15)
      # Steps are nowhere near the ceiling — only tokens should trip the warn.
      Application.put_env(:optimal_system_agent, :budget_warn_steps, 1)

      note = TurnBudget.note(%{session_id: s, iteration: 2}, 1_000)

      assert note =~ "BUDGET NEARLY SPENT"
    end

    test "does not warn when comfortably within budget on both axes" do
      s = sid()
      TurnBudget.start_turn(s)
      TurnBudget.record(s, %{output_tokens: 1_000})
      Application.put_env(:optimal_system_agent, :budget_turn_tokens, 150_000)

      note = TurnBudget.note(%{session_id: s, iteration: 2}, 100)

      refute note =~ "BUDGET NEARLY SPENT"
    end

    test "omits the step portion for an unbounded (:infinity) ceiling" do
      s = sid()
      TurnBudget.start_turn(s)
      Application.put_env(:optimal_system_agent, :budget_turn_tokens, 150_000)

      note = TurnBudget.note(%{session_id: s, iteration: 5}, :infinity)

      refute note =~ "step "
      assert note =~ "tokens ~0/150k"
    end

    test "nil for a state missing session_id or iteration" do
      assert TurnBudget.note(%{}, 10) == nil
      assert TurnBudget.note(%{session_id: "x"}, 10) == nil
    end
  end
end
