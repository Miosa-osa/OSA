defmodule OptimalSystemAgent.Agent.Loop.DoomLoopCapTest do
  @moduledoc """
  The absolute tool-call backstop must not be reachable by a run that is merely
  working.

  A sustained agent averages roughly 10-30 tool calls a minute, so a 12-hour
  unattended run lands in the 7k-20k range. The previous 2000 sat inside that
  band: it halted healthy overnight runs after a few hours and reported it as a
  safety stop. Runaway is caught by the pattern detectors, which fire in seconds
  and do not care how long the session has been alive.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DoomLoop

  @env "OSA_MAX_TOOL_CALLS"

  setup do
    previous_env = System.get_env(@env)
    previous_cfg = Application.fetch_env(:optimal_system_agent, :doom_loop_max_calls)
    System.delete_env(@env)
    Application.delete_env(:optimal_system_agent, :doom_loop_max_calls)

    on_exit(fn ->
      if previous_env, do: System.put_env(@env, previous_env), else: System.delete_env(@env)

      case previous_cfg do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :doom_loop_max_calls, v)
        :error -> Application.delete_env(:optimal_system_agent, :doom_loop_max_calls)
      end
    end)

    :ok
  end

  describe "the default" do
    test "is far beyond anything a real session reaches" do
      # Codex ships no tool-call ceiling at all. Ours stays finite so it can be
      # printed, compared and asserted, but must be unreachable in practice: at
      # a sustained 30 calls a minute a 12-hour run needs ~21_600.
      cap = DoomLoop.max_total_tool_calls()

      assert is_integer(cap)
      assert cap >= 1_000_000, "cap #{cap} is reachable by a long healthy run"
    end

    test "a 12-hour run at a brisk pace does not come close" do
      twelve_hours_at_30_per_min = 12 * 60 * 30
      assert twelve_hours_at_30_per_min < DoomLoop.max_total_tool_calls() / 10
    end
  end

  describe "overriding it" do
    test "application config is honoured" do
      Application.put_env(:optimal_system_agent, :doom_loop_max_calls, 1234)
      assert DoomLoop.max_total_tool_calls() == 1234
    end

    test "the environment variable wins over application config" do
      # An unattended run that trips the cap at 3am cannot be rescued by editing
      # application config, so the env var has to take precedence.
      Application.put_env(:optimal_system_agent, :doom_loop_max_calls, 1234)
      System.put_env(@env, "99000")

      assert DoomLoop.max_total_tool_calls() == 99_000
    end

    test "surrounding whitespace is tolerated" do
      System.put_env(@env, "  4242  ")
      assert DoomLoop.max_total_tool_calls() == 4242
    end
  end

  describe "asking for unlimited explicitly" do
    test "the word forms all mean no limit" do
      for word <- ~w(unlimited none off infinity infinite UNLIMITED  None ) do
        System.put_env(@env, word)

        assert DoomLoop.max_total_tool_calls() == :infinity,
               "#{inspect(word)} should mean no limit at all"
      end
    end
  end

  describe "a bad override is ignored, not obeyed" do
    test "junk falls back to the default" do
      for junk <- ["", "   ", "lots", "12abc", "1e6"] do
        System.put_env(@env, junk)

        assert DoomLoop.max_total_tool_calls() == default(),
               "#{inspect(junk)} was not rejected"
      end
    end

    test "zero and negatives are rejected rather than halting the first tool call" do
      for bad <- ["0", "-1", "-5000"] do
        System.put_env(@env, bad)
        assert DoomLoop.max_total_tool_calls() == default(), "#{bad} was obeyed"
      end
    end
  end

  # The value with no override in play.
  defp default do
    System.delete_env(@env)
    DoomLoop.max_total_tool_calls()
  end
end
