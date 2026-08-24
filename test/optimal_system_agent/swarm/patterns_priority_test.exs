defmodule OptimalSystemAgent.Swarm.PatternsPriorityTest do
  @moduledoc """
  DelegationRouter biases model tier + provider order off `config[:priority]`
  (see `choose/4`'s `Map.get(config, :priority)`). The `delegate` path threads a
  speed/cost priority through, but the orchestrate/swarm path used to stamp only
  `:parent_session_id` and `:delegation_depth`, so swarm agents never got the
  cost benefit. These tests pin that each pattern now threads the caller's
  priority into every spawned config.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Swarm.Patterns

  test "parallel stamps the caller's priority onto every config" do
    parent = self()
    runner = fn config -> send(parent, {:cfg, config}); {:ok, "done"} end

    configs = [%{task: "a", role: "a"}, %{task: "b", role: "b"}]
    {:ok, _} = Patterns.parallel("p1", configs, runner: runner, priority: :loose, timeout: 5_000)

    priorities =
      for _ <- configs do
        assert_receive {:cfg, cfg}
        assert cfg.parent_session_id == "p1"
        cfg.priority
      end

    assert Enum.all?(priorities, &(&1 == :loose)), "every config must carry the caller priority"
  end

  test "priority defaults to :standard when the caller does not pass one" do
    parent = self()
    runner = fn config -> send(parent, {:cfg, config}); {:ok, "done"} end

    {:ok, _} = Patterns.parallel("p2", [%{task: "x", role: "x"}], runner: runner, timeout: 5_000)

    assert_receive {:cfg, cfg}
    assert cfg.priority == :standard
  end
end
