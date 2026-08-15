defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.TruncationGuardTest do
  @moduledoc """
  The reasoning-only guard must not report a truncated model as a stalled one.

  MEASURED, `bench/terminalbench/runs/osa-tb20-full89-f6981b61`,
  `schemelike-metacircular-eval`: the three generations that tripped the "3
  consecutive generations produced no tool calls" guard were the three
  generations that stopped at exactly 32,768 output tokens. The model was
  writing an interpreter and being cut off. The guard halted the episode, and
  its own advice text — "Stopped: 3 consecutive generations produced no tool
  calls… Reconsider the goal" — was delivered to the grader as the final
  answer.

  Two failures compounding. This covers the first: the predicate.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.ReasoningOnly

  defp base_state, do: %{session_id: "truncation-guard-test"}

  describe "a truncated generation is not a reasoning-only spin" do
    test "three truncated generations in a row do NOT trip the guard" do
      # The exact `schemelike` shape: three consecutive tool-less generations,
      # every one of them cut off at the ceiling.
      state = Map.put(base_state(), :turn_truncated, true)

      state =
        Enum.reduce(1..3, state, fn n, acc ->
          assert {:ok, next} = ReasoningOnly.check([], acc),
                 "truncated generation #{n} tripped the reasoning-only guard"

          Map.put(next, :turn_truncated, true)
        end)

      assert Map.get(state, :reasoning_only_streak, 0) == 0,
             "a truncation must not advance the streak"
    end

    test "the streak is left UNCHANGED, not reset" do
      # A truncation is neither progress nor a spin. It must not erase a real
      # spin that was already accumulating around it — only a tool call does.
      state = base_state()
      {:ok, state} = ReasoningOnly.check([], state)
      {:ok, state} = ReasoningOnly.check([], state)
      assert state.reasoning_only_streak == 2

      {:ok, state} = ReasoningOnly.check([], Map.put(state, :turn_truncated, true))

      assert state.reasoning_only_streak == 2,
             "the truncated generation must neither advance nor reset the streak"
    end

    test "a real spin AFTER a truncation still trips at the threshold" do
      state = base_state()
      {:ok, state} = ReasoningOnly.check([], state)
      {:ok, state} = ReasoningOnly.check([], state)
      # One truncation in the middle — excused, and the streak survives it.
      {:ok, state} = ReasoningOnly.check([], Map.put(state, :turn_truncated, true))

      assert {:halt, msg, _state} = ReasoningOnly.check([], state)
      assert msg =~ "reasoning-only"
    end

    test "the truncation flag clears the one-shot errored flag like any other turn" do
      state = base_state() |> Map.put(:turn_truncated, true) |> Map.put(:turn_errored, true)

      assert {:ok, state} = ReasoningOnly.check([], state)
      assert state.turn_errored == false
      assert Map.get(state, :reasoning_only_streak, 0) == 0
    end
  end

  describe "the guard still does its job" do
    test "an untruncated reasoning-only spin trips at the threshold" do
      state = base_state()
      {:ok, state} = ReasoningOnly.check([], state)
      {:ok, state} = ReasoningOnly.check([], state)

      assert {:halt, msg, halted} = ReasoningOnly.check([], state)
      assert msg =~ "3 consecutive generations"
      assert halted.reasoning_only_streak == 0
    end

    test "a tool call resets the streak whether or not a truncation preceded it" do
      state = base_state()
      {:ok, state} = ReasoningOnly.check([], state)
      {:ok, state} = ReasoningOnly.check([], Map.put(state, :turn_truncated, true))

      tc = %{id: "c1", name: "file_read", arguments: %{}}
      assert {:ok, state} = ReasoningOnly.check([tc], state)
      assert state.reasoning_only_streak == 0
    end

    test "an explicitly false truncation flag behaves exactly as an absent one" do
      state = Map.put(base_state(), :turn_truncated, false)
      {:ok, state} = ReasoningOnly.check([], state)
      assert state.reasoning_only_streak == 1
    end
  end
end
