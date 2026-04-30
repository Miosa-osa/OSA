defmodule OptimalSystemAgent.Agent.FastPathTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.FastPath

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

  test "classifies code and schedule intents" do
    assert :code in FastPath.classify_intents("fix the scheduler bug in cron_test.exs")
    assert :schedule in FastPath.classify_intents("fix the scheduler bug in cron_test.exs")
  end

  test "inject_context appends prefetch block without replacing existing context" do
    context = %{messages: [%{role: "system", content: "base"}]}

    updated =
      FastPath.inject_context(context, %{
        git_status: " M lib/example.ex",
        git_changed: "lib/example.ex",
        file_hints: ["lib/example.ex"]
      })

    assert length(updated.messages) == 2
    assert List.last(updated.messages).content =~ "[Fast path prefetch]"
    assert List.last(updated.messages).content =~ "lib/example.ex"
  end
end
