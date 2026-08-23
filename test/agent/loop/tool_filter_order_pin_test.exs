defmodule OptimalSystemAgent.Agent.Loop.ToolFilterOrderPinTest do
  @moduledoc """
  Anthropic caches the `tools` array as the first bytes of the prompt prefix.
  Identical JSON bytes are required for a cache hit; shuffling names mid-session
  is a full prefix rewrite.

  `ToolFilter.filter/2` must pin the ORDER of names after the first call of a
  session. Subsequent calls with the same state (and even a shuffled input
  list) yield that same name order. Newly discovered tools append at the tail.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ToolFilter

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    Effort.set(:medium)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  defp names(tools), do: Enum.map(tools, & &1.name)

  defp tools(list), do: Enum.map(list, &%{name: &1, description: &1, parameters: %{}})

  defp state(session_id) do
    %{
      session_id: session_id,
      provider: :anthropic,
      model: "claude-sonnet-4-6",
      messages: []
    }
  end

  describe "filter/2 pins name order for the session" do
    test "two calls with the same state yield the same name order" do
      session = "pin-#{:erlang.unique_integer([:positive])}"
      input = tools(~w(zeta alpha gamma))

      first = ToolFilter.filter(input, state(session)) |> names()
      second = ToolFilter.filter(input, state(session)) |> names()

      assert first == second
      assert length(first) == 3
    end

    test "a shuffled input on the second call still returns the first-call order" do
      session = "pin-#{:erlang.unique_integer([:positive])}"
      original = tools(~w(file_read shell_execute git web_search))
      shuffled = tools(~w(web_search git shell_execute file_read))

      pinned = ToolFilter.filter(original, state(session)) |> names()
      again = ToolFilter.filter(shuffled, state(session)) |> names()

      assert again == pinned
      refute again == names(shuffled),
             "the second call followed the shuffled input instead of the pinned order"
    end

    test "a name that appears after the first call is appended, not interleaved" do
      session = "pin-#{:erlang.unique_integer([:positive])}"
      first_input = tools(~w(file_read shell_execute))
      second_input = tools(~w(mcp__late__tool shell_execute file_read))

      first = ToolFilter.filter(first_input, state(session)) |> names()
      second = ToolFilter.filter(second_input, state(session)) |> names()

      assert first == ~w(file_read shell_execute)
      assert second == ~w(file_read shell_execute mcp__late__tool)
    end
  end
end
