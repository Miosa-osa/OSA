defmodule OptimalSystemAgent.MCP.VirtualizationTest do
  @moduledoc """
  Unit tests for the tool-virtualization gate (steal-list 11g).

  Covers the mode/threshold decision matrix and `apply_decision/1`, which stamps
  a uniform `:should_defer?` onto an aggregate `mcp_tools` map. The key
  guarantee is the "unchanged for small toolsets" path: under the default
  `:auto` mode a small toolset is NOT virtualized (tools inject directly),
  while a large one is.
  """
  # async: false — mutates the {:optimal_system_agent, :mcp_virtualization}
  # application env, which is process-global.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Virtualization

  setup do
    prev_mode = Application.get_env(:optimal_system_agent, :mcp_virtualization)
    prev_thresh = Application.get_env(:optimal_system_agent, :mcp_virtualization_threshold)

    on_exit(fn ->
      restore(:mcp_virtualization, prev_mode)
      restore(:mcp_virtualization_threshold, prev_thresh)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp entry(defer?),
    do: %{
      original_name: "t",
      server: "s",
      description: "d",
      input_schema: %{},
      should_defer?: defer?
    }

  describe "mode/0" do
    test "defaults to :auto" do
      Application.delete_env(:optimal_system_agent, :mcp_virtualization)
      assert Virtualization.mode() == :auto
    end

    test "accepts atoms and string equivalents" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :on)
      assert Virtualization.mode() == :on
      Application.put_env(:optimal_system_agent, :mcp_virtualization, "off")
      assert Virtualization.mode() == :off
      Application.put_env(:optimal_system_agent, :mcp_virtualization, true)
      assert Virtualization.mode() == :on
    end

    test "falls back to :auto on garbage" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :nonsense)
      assert Virtualization.mode() == :auto
    end
  end

  describe "virtualize?/1 in :auto mode" do
    setup do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 10)
      :ok
    end

    test "does NOT virtualize at or below the threshold (small-toolset path)" do
      refute Virtualization.virtualize?(0)
      refute Virtualization.virtualize?(3)
      refute Virtualization.virtualize?(10)
    end

    test "virtualizes above the threshold" do
      assert Virtualization.virtualize?(11)
      assert Virtualization.virtualize?(50)
    end

    test "honors a custom threshold" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 2)
      refute Virtualization.virtualize?(2)
      assert Virtualization.virtualize?(3)
    end
  end

  describe "virtualize?/1 in :on / :off modes" do
    test ":on virtualizes whenever any tool exists" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :on)
      refute Virtualization.virtualize?(0)
      assert Virtualization.virtualize?(1)
    end

    test ":off never virtualizes, even for huge toolsets" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :off)
      refute Virtualization.virtualize?(0)
      refute Virtualization.virtualize?(1)
      refute Virtualization.virtualize?(1_000)
    end
  end

  describe "apply_decision/1" do
    test "defers every entry when the aggregate is large (:auto)" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 2)

      # 3 tools > threshold 2 → virtualize (defer all)
      aggregate = %{"a" => entry(false), "b" => entry(false), "c" => entry(false)}
      result = Virtualization.apply_decision(aggregate)

      assert Enum.all?(result, fn {_k, info} -> info.should_defer? == true end)
    end

    test "un-defers every entry when the aggregate is small (:auto, small-toolset path)" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 10)

      # 2 tools <= threshold 10 → inject directly (defer none), overriding the
      # build_tools default of should_defer?: true.
      aggregate = %{"a" => entry(true), "b" => entry(true)}
      result = Virtualization.apply_decision(aggregate)

      assert Enum.all?(result, fn {_k, info} -> info.should_defer? == false end)
    end

    test ":off always un-defers (direct injection)" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :off)
      aggregate = Map.new(1..50, fn i -> {"t#{i}", entry(true)} end)
      result = Virtualization.apply_decision(aggregate)
      assert Enum.all?(result, fn {_k, info} -> info.should_defer? == false end)
    end

    test "preserves all other entry fields" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :on)
      aggregate = %{"a" => entry(false)}
      %{"a" => info} = Virtualization.apply_decision(aggregate)
      assert info.original_name == "t"
      assert info.server == "s"
      assert info.should_defer? == true
    end

    test "handles the empty aggregate" do
      assert Virtualization.apply_decision(%{}) == %{}
    end
  end

  describe "cost_estimate/0" do
    alias OptimalSystemAgent.Tools.Registry
    alias OptimalSystemAgent.MCP.Client.ToolBridge

    @pt_key {Registry, :mcp_tools}

    setup do
      prior = :persistent_term.get(@pt_key, %{})
      on_exit(fn -> :persistent_term.put(@pt_key, prior) end)
      :ok
    end

    defp publish(server, count) do
      schemas =
        for i <- 1..count do
          %{
            "name" => "tool_#{i}",
            "description" => "a tool",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          }
        end

      tools = ToolBridge.build_tools(server, schemas, nil)
      # Replace, not merge: every caller below asserts an EXACT tool_count
      # from cost_estimate/0. Merging onto whatever :persistent_term already
      # held made the assertion depend on ambient state left by any other
      # test that registers (and fails to clean up) an mcp tool in the same
      # global slot — see mcp_routes_test.exs's `publish/2` for the same fix
      # and the leak this closes (pagination_test.exs / progress_timeout_test.exs).
      :persistent_term.put(@pt_key, tools)
    end

    test "reports zero for an empty toolset" do
      :persistent_term.put(@pt_key, %{})
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)

      assert Virtualization.cost_estimate() == %{
               tool_count: 0,
               server_count: 0,
               virtualized: false,
               estimated_tokens: 0
             }
    end

    test "below threshold: not virtualized, cost reflects the native schemas" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 10)
      # apply_decision/1 runs in MCP.Client.Manager.republish/1, not on the
      # raw ToolBridge output — publish already-decided (should_defer?: false)
      # entries directly so this test does not depend on the Manager GenServer.
      publish("small", 3)

      :persistent_term.put(
        @pt_key,
        Map.new(:persistent_term.get(@pt_key), fn {k, v} -> {k, %{v | should_defer?: false}} end)
      )

      result = Virtualization.cost_estimate()

      assert result.tool_count == 3
      assert result.server_count == 1
      assert result.virtualized == false
      # 3 small tools serialize to well under a couple hundred tokens.
      assert result.estimated_tokens > 0
      assert result.estimated_tokens < 500
    end

    test "above threshold: virtualized, cost reflects the capped catalog, not the schemas" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 10)
      publish("huge", 200)

      result = Virtualization.cost_estimate()

      assert result.tool_count == 200
      assert result.server_count == 1
      assert result.virtualized == true
      # The whole point of virtualization: 200 schemas collapse to a small
      # catalog line, not hundreds of tool descriptions worth of tokens.
      assert result.estimated_tokens > 0
      assert result.estimated_tokens < 200
    end

    test ":off mode never virtualizes regardless of count" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :off)
      publish("many", 50)

      result = Virtualization.cost_estimate()

      assert result.virtualized == false
      assert result.tool_count == 50
    end
  end
end
