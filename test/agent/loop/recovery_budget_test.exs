defmodule OptimalSystemAgent.Agent.Loop.RecoveryBudgetTest do
  @moduledoc """
  P2 audit gap C: one shared per-turn recovery budget across every
  failure-recovery path — truncation with or without tool calls, a cut-off
  stream, and an invalid-tool-call REASK. Before this, several of these paths
  had independent (or no) counters, and the truncated-tool-calls path
  recursed straight into `run/1`, bypassing `continue_after_tools/4` — the
  ONE place the doom-loop detectors (`DoomLoop.check/3`) run. These tests
  drive the real loop against `MockProvider`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  @user_message "please rename the config key everywhere"

  setup do
    prev = %{
      provider: Application.get_env(:optimal_system_agent, :default_provider),
      text: Application.get_env(:optimal_system_agent, :mock_provider_final_text),
      stop: Application.get_env(:optimal_system_agent, :mock_provider_stop_reason),
      tool_calls: Application.get_env(:optimal_system_agent, :mock_provider_tool_calls),
      incomplete: Application.get_env(:optimal_system_agent, :mock_provider_stream_incomplete),
      max_iter: Application.get_env(:optimal_system_agent, :max_iterations),
      resample: Application.get_env(:optimal_system_agent, :doom_loop_resample)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 30)
    # Deterministic: a resample re-rolls the SAME turn on a detected loop,
    # which would make the exact round-trip count depend on the resample
    # budget too. Disabling it isolates what these tests are about — the
    # shared recovery budget and doom-loop VISIBILITY, not the resample remedy
    # (covered by doom_loop_resample_test.exs).
    Application.put_env(:optimal_system_agent, :doom_loop_resample, enabled: false)

    on_exit(fn ->
      restore(:default_provider, prev.provider)
      restore(:mock_provider_final_text, prev.text)
      restore(:mock_provider_stop_reason, prev.stop)
      restore(:mock_provider_tool_calls, prev.tool_calls)
      restore(:mock_provider_stream_incomplete, prev.incomplete)
      restore(:max_iterations, prev.max_iter)
      restore(:doom_loop_resample, prev.resample)
      Application.delete_env(:optimal_system_agent, :mock_provider_after_call_once)
      MockProvider.reset_stream_incomplete()
      MockProvider.reset_final_texts()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp sid, do: "recovery-budget-#{System.unique_integer([:positive])}"

  defp base_state do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: sid(),
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      overflow_retries: 0,
      messages: [%{role: "user", content: @user_message}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  describe "truncated-with-tool-calls is routed through continue_after_tools" do
    test "the doom-loop detector sees repeated identical truncated tool calls and halts — " <>
           "it does not spin to the shared recovery ceiling" do
      # Same tool call, same stop_reason, on every round-trip. Before this fix
      # this clause called `run/1` directly, so `DoomLoop.check/3` (which lives
      # in `continue_after_tools/4`) never even saw it — nothing but the
      # (then-nonexistent) shared budget or `max_iterations` would ever have
      # stopped this.
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Renaming now.")
      Application.put_env(:optimal_system_agent, :mock_provider_stop_reason, "length")

      Application.put_env(:optimal_system_agent, :mock_provider_tool_calls, [
        %{id: "call_1", name: "file_edit", arguments: %{"path" => "/tmp/x", "old_string" => "a"}}
      ])

      MockProvider.reset_round_trips()
      {response, _state} = ReactLoop.run(base_state())

      assert is_binary(response)

      # Bounded well under the shared recovery ceiling (1 initial + 6 retries
      # = 7) — proof that SOMETHING other than that generic budget ended the
      # turn early, which can only be the doom-loop detector now seeing this
      # path via `continue_after_tools/4`.
      assert MockProvider.round_trips() < 7,
             "expected the doom-loop detector to halt this before the shared recovery " <>
               "budget did (got #{MockProvider.round_trips()} round-trips) — is the " <>
               "truncated-tool-calls path still bypassing continue_after_tools/4?"
    end
  end

  describe "the shared recovery budget bounds a truncated-tool-calls loop even without a doom-loop trip" do
    test "each round uses a DIFFERENT tool call (never repeats, so the doom-loop detector " <>
           "never fires) — the shared budget still ends the turn" do
      Application.put_env(:optimal_system_agent, :mock_provider_stop_reason, "length")
      MockProvider.reset_round_trips()

      # A fresh tool call id/args every round: never identical twice, so
      # neither IdenticalCall nor FailureSignature ever accumulates a repeat.
      # Only the shared per-turn budget bounds this.
      differing_call = fn ->
        n = MockProvider.round_trips()

        Application.put_env(:optimal_system_agent, :mock_provider_tool_calls, [
          %{id: "call_#{n}", name: "file_edit", arguments: %{"path" => "/tmp/x_#{n}"}}
        ])
      end

      rearm = fn rearm ->
        differing_call.()

        Application.put_env(:optimal_system_agent, :mock_provider_after_call_once, fn ->
          rearm.(rearm)
        end)
      end

      differing_call.()

      Application.put_env(:optimal_system_agent, :mock_provider_after_call_once, fn ->
        rearm.(rearm)
      end)

      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Renaming now.")

      {response, state} = ReactLoop.run(base_state())

      assert is_binary(response)
      # 1 initial + @max_recovery_attempts(6) retries, never unbounded.
      assert MockProvider.round_trips() == 7
      assert Map.get(state, :recovery_attempts, 0) == 6
    end
  end

  describe "the shared budget is spent ACROSS different failure kinds, not per-kind" do
    test "a truncated-tool-call round, then only cut-off-stream rounds, still exhausts at " <>
           "the SAME shared ceiling — the second kind does not get its own fresh budget" do
      # Round 1: a truncated tool call (spends 1 of the shared budget). Every
      # round after that switches to a stream cut off with nothing shown — a
      # DIFFERENT failure kind. If each kind had its own independent budget,
      # round 1's spend on the tool-call kind would not count against the
      # stream-incomplete kind's budget, and this would take 1 + 7 = 8
      # round-trips (or more) to terminate. A single shared counter caps the
      # total at 7 regardless of how the kinds mix.
      Application.put_env(:optimal_system_agent, :mock_provider_stop_reason, "length")

      Application.put_env(:optimal_system_agent, :mock_provider_tool_calls, [
        %{id: "call_1", name: "file_edit", arguments: %{"path" => "/tmp/x"}}
      ])

      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "Renaming now.")

      Application.put_env(:optimal_system_agent, :mock_provider_after_call_once, fn ->
        # From round 2 onward: no more tool calls, no more forced truncation —
        # just an empty, stream_incomplete response, repeated for every
        # remaining round-trip.
        Application.delete_env(:optimal_system_agent, :mock_provider_tool_calls)
        Application.delete_env(:optimal_system_agent, :mock_provider_stop_reason)
        Application.put_env(:optimal_system_agent, :mock_provider_final_text, "")
        Application.put_env(:optimal_system_agent, :mock_provider_stream_incomplete, true)
      end)

      MockProvider.reset_round_trips()
      {response, state} = ReactLoop.run(base_state())

      assert is_binary(response)
      # 1 (truncated tool call) + 6 (stream-incomplete retries) = 7 total —
      # the SAME ceiling as either kind alone, not the sum of two independent
      # budgets.
      assert MockProvider.round_trips() == 7,
             "expected one shared budget spanning both failure kinds, got " <>
               "#{MockProvider.round_trips()} round-trips"

      assert Map.get(state, :recovery_attempts, 0) == 6
    end
  end
end
