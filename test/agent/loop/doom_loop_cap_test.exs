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

  describe "the default backstop" do
    test "clears a 12-hour run at a sustained pace" do
      cap = DoomLoop.max_total_tool_calls()

      # 12h at a brisk 20 calls/min. The cap is a runaway net, not a clock.
      assert cap >= 12 * 60 * 20,
             "cap #{cap} halts a healthy 12-hour run before it finishes"
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

  describe "a bad override is ignored, not obeyed" do
    test "junk falls back to the default" do
      default = DoomLoop.max_total_tool_calls()

      for junk <- ["", "   ", "lots", "12abc", "1e6"] do
        System.put_env(@env, junk)

        assert DoomLoop.max_total_tool_calls() == default,
               "#{inspect(junk)} was not rejected"
      end
    end

    test "zero and negatives are rejected rather than halting the first tool call" do
      default = DoomLoop.max_total_tool_calls()

      for bad <- ["0", "-1", "-5000"] do
        System.put_env(@env, bad)
        assert DoomLoop.max_total_tool_calls() == default, "#{bad} was obeyed"
      end
    end
  end
end
