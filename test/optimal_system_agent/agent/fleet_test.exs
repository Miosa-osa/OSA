defmodule OptimalSystemAgent.Agent.FleetTest do
  @moduledoc """
  FleetView B2 — global fleet cap (spawn-bomb protection) + agent-type
  system-prompt/tool resolution. These do NOT boot real loops; they exercise the
  pure guard + resolution logic against a seeded RunStore.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.RunStore

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_fleet_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_runs = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    prev_cap = Application.get_env(:optimal_system_agent, :max_fleet_agents)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      restore_env(:agent_runs_dir, prev_runs)
      restore_env(:max_fleet_agents, prev_cap)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp seed_running(n, parent) do
    Enum.each(1..n, fn i ->
      RunStore.start_run(%{
        agent_id: "fleet-seed-#{parent}-#{i}-#{System.unique_integer([:positive])}",
        parent_session_id: parent,
        role: "general-purpose",
        task: "seed"
      })
    end)
  end

  describe "max_fleet_agents/0" do
    test "defaults to 16 and is configurable" do
      Application.delete_env(:optimal_system_agent, :max_fleet_agents)
      assert Fleet.max_fleet_agents() == 16

      Application.put_env(:optimal_system_agent, :max_fleet_agents, 4)
      assert Fleet.max_fleet_agents() == 4
    end
  end

  describe "spawn_fleet_node/2 fleet cap" do
    test "refuses to spawn when the running fleet is at capacity" do
      parent = "parent-#{System.unique_integer([:positive])}"
      Application.put_env(:optimal_system_agent, :max_fleet_agents, 2)
      seed_running(2, parent)

      assert {:error, {:fleet_cap_reached, running, cap}} =
               Fleet.spawn_fleet_node(parent, agent_type: "general-purpose", task: "hi")

      assert cap == 2
      assert running >= 2
    end

    test "rejects a non-binary parent id" do
      assert {:error, :invalid_parent_session_id} = Fleet.spawn_fleet_node(nil)
    end
  end

  describe "resolve_agent_type/2" do
    test "explicit system_prompt override wins and imposes no tool allowlist" do
      assert {"custom prompt", nil} = Fleet.resolve_agent_type("code-reviewer", "custom prompt")
    end

    test "built-in general-purpose fallback has full tools (nil allowlist)" do
      # Assumes no AGENT.md 'general-purpose' overrides in this env; falls through
      # to the built-in table.
      {prompt, tools} = Fleet.resolve_agent_type("general-purpose")
      assert is_binary(prompt)
      assert tools == nil
    end

    test "built-in code-reviewer fallback is restricted to read-only tools" do
      case OptimalSystemAgent.Agents.Registry.get("code-reviewer") do
        nil ->
          {prompt, tools} = Fleet.resolve_agent_type("code-reviewer")
          assert is_binary(prompt)
          assert is_list(tools)
          refute "file_write" in tools

        _def ->
          # A project/user AGENT.md defines code-reviewer — resolution still works.
          {prompt, _tools} = Fleet.resolve_agent_type("code-reviewer")
          assert prompt == nil or is_binary(prompt)
      end
    end

    test "an unknown agent-type resolves to {nil, nil}" do
      assert {nil, nil} = Fleet.resolve_agent_type("no-such-type-xyz")
    end
  end
end
