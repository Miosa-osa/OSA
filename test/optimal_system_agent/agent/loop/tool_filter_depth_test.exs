defmodule OptimalSystemAgent.Agent.Loop.ToolFilterDepthTest do
  @moduledoc """
  Delegation depth guard (primitive #34 / orchestrator fork-bomb ceiling).

  `ToolFilter.apply_delegation_depth_guard/2` strips the spawning tools
  (delegate / create_agent / …) from a subagent's tool list once its
  `:delegation_depth` reaches the configured `max_delegation_depth`, so a
  runaway orchestrator under auto-mode cannot recursively fork children without
  bound. Non-spawning tools are always retained.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolFilter

  # Spawning + non-spawning tools. Uses :anthropic (non-local) and empty
  # messages so only the depth guard / policy layers are exercised — the
  # local-provider budget and weight gate stay inert.
  defp tools do
    ~w(file_read shell_execute delegate create_agent)
    |> Enum.map(&%{name: &1})
  end

  defp names(filtered), do: Enum.map(filtered, & &1.name)

  defp filter_at_depth(depth) do
    ToolFilter.filter(tools(), %{
      provider: :anthropic,
      messages: [],
      delegation_policy: :proactive,
      delegation_depth: depth
    })
  end

  setup do
    prev = Application.get_env(:optimal_system_agent, :max_delegation_depth)

    on_exit(fn ->
      if prev do
        Application.put_env(:optimal_system_agent, :max_delegation_depth, prev)
      else
        Application.delete_env(:optimal_system_agent, :max_delegation_depth)
      end
    end)

    :ok
  end

  describe "max_delegation_depth/0" do
    test "defaults to 3 when unconfigured" do
      Application.delete_env(:optimal_system_agent, :max_delegation_depth)
      assert ToolFilter.max_delegation_depth() == 3
    end

    test "reads the configured override" do
      Application.put_env(:optimal_system_agent, :max_delegation_depth, 1)
      assert ToolFilter.max_delegation_depth() == 1
    end
  end

  describe "depth guard (default max = 3)" do
    setup do
      Application.put_env(:optimal_system_agent, :max_delegation_depth, 3)
      :ok
    end

    test "depth 0 (root) keeps spawning tools" do
      n = names(filter_at_depth(0))
      assert "delegate" in n
      assert "create_agent" in n
    end

    test "depth below the cap keeps spawning tools" do
      n = names(filter_at_depth(2))
      assert "delegate" in n
      assert "create_agent" in n
    end

    test "depth at the cap strips spawning tools but keeps the rest" do
      n = names(filter_at_depth(3))
      refute "delegate" in n
      refute "create_agent" in n
      assert "file_read" in n
      assert "shell_execute" in n
    end

    test "depth beyond the cap strips spawning tools" do
      n = names(filter_at_depth(9))
      refute "delegate" in n
      refute "create_agent" in n
    end

    test "missing delegation_depth is treated as 0 (root, spawning allowed)" do
      n =
        ToolFilter.filter(tools(), %{provider: :anthropic, messages: []})
        |> names()

      assert "delegate" in n
    end
  end

  describe "depth guard honours a lower configured ceiling" do
    test "cap = 1 strips spawning tools at depth 1" do
      Application.put_env(:optimal_system_agent, :max_delegation_depth, 1)
      n = names(filter_at_depth(1))
      refute "delegate" in n
      assert "file_read" in n
    end

    test "cap = 1 keeps spawning tools at depth 0" do
      Application.put_env(:optimal_system_agent, :max_delegation_depth, 1)
      assert "delegate" in names(filter_at_depth(0))
    end
  end
end
