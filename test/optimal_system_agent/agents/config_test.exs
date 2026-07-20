defmodule OptimalSystemAgent.Agents.ConfigTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agents.Config
  alias OptimalSystemAgent.Settings

  setup do
    # Session layer is highest-priority and cheap to set/clear per test.
    on_exit(fn -> Settings.set_session("agent_overrides", %{}) end)
    :ok
  end

  describe "model_override/1" do
    test "returns nil when no overrides configured" do
      Settings.set_session("agent_overrides", %{})
      assert Config.model_override("code-reviewer") == nil
    end

    test "returns nil for nil / unknown agent" do
      Settings.set_session("agent_overrides", %{"debugger" => %{"model" => "glm-5.2:cloud"}})
      assert Config.model_override(nil) == nil
      assert Config.model_override("no-such-agent") == nil
    end

    test "returns the configured model for a matching agent" do
      Settings.set_session("agent_overrides", %{
        "code-reviewer" => %{"model" => "glm-5.2:cloud"}
      })

      assert Config.model_override("code-reviewer") == "glm-5.2:cloud"
    end

    test "ignores blank model values" do
      Settings.set_session("agent_overrides", %{"code-reviewer" => %{"model" => ""}})
      assert Config.model_override("code-reviewer") == nil
    end
  end

  describe "tier_override/1" do
    test "parses a valid tier string to an atom" do
      Settings.set_session("agent_overrides", %{"code-reviewer" => %{"tier" => "elite"}})
      assert Config.tier_override("code-reviewer") == :elite
    end

    test "rejects an invalid tier string" do
      Settings.set_session("agent_overrides", %{"code-reviewer" => %{"tier" => "bogus"}})
      assert Config.tier_override("code-reviewer") == nil
    end

    test "returns nil when unset" do
      Settings.set_session("agent_overrides", %{"code-reviewer" => %{"model" => "x"}})
      assert Config.tier_override("code-reviewer") == nil
    end
  end
end
