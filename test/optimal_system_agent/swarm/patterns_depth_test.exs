defmodule OptimalSystemAgent.Swarm.PatternsDepthTest do
  @moduledoc """
  The fork-bomb ceiling (`ToolFilter.apply_delegation_depth_guard`) depends on a
  subagent's delegation_depth growing with true nesting. The swarm patterns used
  to stamp only `:parent_session_id`, so `run_subagent` incremented from a
  default of 0 and every orchestrate-spawned child started at depth 1 regardless
  of how deep the caller already was. These tests pin that each pattern now
  threads the caller's depth into every spawned config.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Swarm.Patterns

  test "parallel stamps the caller's depth onto every config" do
    parent = self()
    runner = fn config -> send(parent, {:cfg, config}); {:ok, "done"} end

    configs = [%{task: "a", role: "a"}, %{task: "b", role: "b"}]
    {:ok, _} = Patterns.parallel("p1", configs, runner: runner, depth: 2, timeout: 5_000)

    depths =
      for _ <- configs do
        assert_receive {:cfg, cfg}
        assert cfg.parent_session_id == "p1"
        cfg.delegation_depth
      end

    assert Enum.all?(depths, &(&1 == 2)), "every config must carry the caller depth (2)"
  end

  test "depth defaults to 0 when the caller does not pass one" do
    parent = self()
    runner = fn config -> send(parent, {:cfg, config}); {:ok, "done"} end

    {:ok, _} = Patterns.parallel("p2", [%{task: "x", role: "x"}], runner: runner, timeout: 5_000)

    assert_receive {:cfg, cfg}
    assert cfg.delegation_depth == 0
  end
end
