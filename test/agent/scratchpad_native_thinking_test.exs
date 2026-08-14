defmodule OptimalSystemAgent.Agent.ScratchpadNativeThinkingTest do
  @moduledoc """
  The first of `Scratchpad.inject?/1`'s two mirror-image failures: an Anthropic
  turn with thinking switched OFF used to get neither native thinking nor the
  `<think>` scaffold, and reasoned in no channel at all — silently.

  Separate from `ScratchpadTest` and `async: false` on purpose. Both cases here
  are reached by flipping GLOBAL state — the `:thinking_enabled` application env
  and the process-wide effort ladder — which an `async: true` test may not do:
  any concurrently running test that builds a prompt or resolves a thinking
  decision would read the flipped value and fail for a reason that has nothing to
  do with it. (Observed: adding these to the async file made
  `Context.PromptTemplateTest` and `SettingsBomTest` fail intermittently.)
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Scratchpad

  setup do
    prev_scratchpad = Application.get_env(:optimal_system_agent, :scratchpad_enabled)
    prev_thinking = Application.get_env(:optimal_system_agent, :thinking_enabled)
    prev_effort = Effort.current()

    Application.put_env(:optimal_system_agent, :scratchpad_enabled, true)

    on_exit(fn ->
      restore(:scratchpad_enabled, prev_scratchpad)
      restore(:thinking_enabled, prev_thinking)
      Effort.set(prev_effort)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  test "Anthropic with thinking disabled by config gets the scaffold" do
    Application.put_env(:optimal_system_agent, :thinking_enabled, false)

    assert Scratchpad.inject?(%{provider: :anthropic, model: nil})
    assert {true, :no_native_thinking} = Scratchpad.decision(%{provider: :anthropic})
  end

  test "Anthropic in fast mode gets the scaffold" do
    # Same loss reached through the effort ladder rather than the config flag:
    # `Effort.fast_mode?/0` makes `LLMClient.thinking_decision/1` return
    # `{nil, :fast_mode}`, so there is no native channel to defer to.
    :ok = Effort.set(:fast)

    assert Scratchpad.inject?(%{provider: :anthropic, model: nil})
    assert {true, :no_native_thinking} = Scratchpad.decision(%{provider: :anthropic})
  end

  test "Anthropic with thinking ON does NOT get the scaffold" do
    # The control. Native extended thinking is on the wire, so a second,
    # hand-rolled reasoning channel would be redundant.
    Application.put_env(:optimal_system_agent, :thinking_enabled, true)
    :ok = Effort.set(:high)

    assert {false, :native_thinking} =
             Scratchpad.decision(%{provider: :anthropic, model: "claude-opus-5"})
  end
end
