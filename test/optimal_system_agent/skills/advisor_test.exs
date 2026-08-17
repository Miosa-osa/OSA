defmodule OptimalSystemAgent.Skills.AdvisorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Skills.Advisor

  setup do
    Advisor.clear_cache()
    :ok
  end

  test "ranks trigger and metadata matches without returning skill bodies" do
    skills = [
      %{name: "deploy", description: "ship a release", triggers: ["publish"], body: "secret"},
      %{
        name: "diagnose",
        description: "debug broken behavior",
        triggers: ["broken"],
        body: "body"
      }
    ]

    assert [%{skill: %{name: "diagnose"}, confidence: :high}] =
             Advisor.recommend(skills, "the TUI is broken", limit: 1)
  end

  test "reuses a cached recommendation and invalidates when metadata changes" do
    id = "advisor-cache-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:osa, :skills, :recommend],
      fn _event, measurements, _metadata, pid -> send(pid, measurements) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    skills = [%{name: "diagnose", description: "debug failures", triggers: []}]

    assert [_] = Advisor.recommend(skills, "debug")
    assert_receive %{cache_hit: 0}
    assert [_] = Advisor.recommend(skills, "debug")
    assert_receive %{cache_hit: 1}

    changed = [%{name: "diagnose", description: "inspect failures", triggers: []}]
    assert Advisor.recommend(changed, "debug") == []
    assert_receive %{cache_hit: 0}
  end
end
