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
    do: %{original_name: "t", server: "s", description: "d", input_schema: %{}, should_defer?: defer?}

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
end
