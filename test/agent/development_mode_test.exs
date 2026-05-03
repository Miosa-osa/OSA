defmodule OptimalSystemAgent.Agent.DevelopmentModeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.DevelopmentMode

  test "parses aliases into stable development modes" do
    assert DevelopmentMode.parse("debug") == :diagnose
    assert DevelopmentMode.parse("build") == :implement
    assert DevelopmentMode.parse("verify") == :test
    assert DevelopmentMode.parse("unknown") == nil
  end

  test "policies define execution posture and verification expectations" do
    explore = DevelopmentMode.policy(:explore)
    implement = DevelopmentMode.policy(:implement)

    assert explore.permission_tier == :read_only
    assert explore.background
    refute implement.background
    assert "summary" in implement.required_output
    assert implement.verification != []
  end

  test "annotates delegated prompts with mode-specific guidance" do
    annotated = DevelopmentMode.annotate_task("Inspect the repo", :explore)

    assert annotated =~ "## Development Mode"
    assert annotated =~ "Mode: explore"
    assert annotated =~ "Required output:"
  end
end
