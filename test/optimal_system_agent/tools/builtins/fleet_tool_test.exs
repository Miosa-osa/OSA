defmodule OptimalSystemAgent.Tools.Builtins.Fleet.ToolTest do
  @moduledoc """
  Handler-level tests for the `fleet` tool: input validation, permission
  gating, the full-power spawn path, and the ULTRA-GATED workflow path.

  These do NOT boot real agent loops — the per-item spawn is injected through
  the `:fleet_spawn_fun` app-env seam. The ultra-gate itself always lives in
  `Agent.Fleet.fan_out/3`, so injecting a fake spawn never bypasses it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Tools.Builtins.Fleet.Handler
  alias OptimalSystemAgent.Tools.Builtins.Fleet.Tool
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    prev_spawn = Application.get_env(:optimal_system_agent, :fleet_spawn_fun)
    prev_effort = Application.get_env(:optimal_system_agent, :effort_level)

    on_exit(fn ->
      restore(:fleet_spawn_fun, prev_spawn)
      restore(:effort_level, prev_effort)
    end)

    {:ok, ctx: UseContext.new(%{session_id: "parent-#{System.unique_integer([:positive])}"})}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp put_spawn(fun), do: Application.put_env(:optimal_system_agent, :fleet_spawn_fun, fun)

  describe "identity + schema" do
    test "name is fleet and schema is plain (no Union/anyOf/oneOf/format)" do
      assert Tool.name() == "fleet"
      schema = Tool.parameters()
      # Hard schema constraint: no forbidden constructs anywhere in the schema.
      json = inspect(schema)
      refute json =~ "anyOf"
      refute json =~ "oneOf"
      refute json =~ "Type.Union"
      refute Map.has_key?(schema["properties"], "format")
      assert schema["properties"]["action"]["enum"] == ["spawn", "workflow"]
    end
  end

  describe "validate/2" do
    test "missing action", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx)
      assert msg =~ "action"
    end

    test "unknown action", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "nope"}, ctx)
      assert msg =~ "Unknown action"
    end

    test "spawn requires a string task", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "spawn"}, ctx)
      assert msg =~ "task"
    end

    test "workflow requires an items array", %{ctx: ctx} do
      assert {:error, msg, -32_602} = Handler.validate(%{"action" => "workflow"}, ctx)
      assert msg =~ "items"
    end

    test "workflow rejects an empty items array with a clear message", %{ctx: ctx} do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"action" => "workflow", "items" => []}, ctx)

      assert msg =~ "non-empty"
      assert msg =~ "items"
    end

    test "accepts valid spawn + workflow inputs", %{ctx: ctx} do
      assert {:ok, _} = Handler.validate(%{"action" => "spawn", "task" => "do it"}, ctx)
      assert {:ok, _} = Handler.validate(%{"action" => "workflow", "items" => ["a"]}, ctx)
    end
  end

  describe "check_permissions/2" do
    test "denies a blank spawn task", %{ctx: ctx} do
      assert {:deny, _} = Handler.check_permissions(%{"action" => "spawn", "task" => "   "}, ctx)
    end

    test "denies non-string workflow items", %{ctx: ctx} do
      assert {:deny, _} =
               Handler.check_permissions(%{"action" => "workflow", "items" => [1, 2]}, ctx)
    end

    test "allows valid spawn + workflow", %{ctx: ctx} do
      assert {:allow, _} =
               Handler.check_permissions(%{"action" => "spawn", "task" => "go"}, ctx)

      assert {:allow, _} =
               Handler.check_permissions(%{"action" => "workflow", "items" => ["a"]}, ctx)
    end
  end

  describe "execute/2 — spawn (any effort)" do
    test "returns node id + confirmation, forwarding task/agent_type", %{ctx: ctx} do
      Effort.set(:low)
      test_pid = self()

      put_spawn(fn parent, opts ->
        send(test_pid, {:spawned, parent, opts})
        {:ok, "fleet:#{parent}:1"}
      end)

      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "spawn", "task" => "reindex", "agent_type" => "code-reviewer"},
                 ctx
               )

      assert msg =~ "Spawned full-power fleet node"
      assert msg =~ "code-reviewer"
      assert_received {:spawned, _parent, opts}
      assert Keyword.get(opts, :task) == "reindex"
      assert Keyword.get(opts, :agent_type) == "code-reviewer"
    end

    test "surfaces the fleet cap message", %{ctx: ctx} do
      put_spawn(fn _p, _o -> {:error, {:fleet_cap_reached, 16, 16}} end)

      assert {:ok, msg} = Handler.execute(%{"action" => "spawn", "task" => "x"}, ctx)
      assert msg =~ "Fleet at capacity (16/16)"
    end

    test "surfaces an arbitrary spawn failure gracefully (no crash)", %{ctx: ctx} do
      put_spawn(fn _p, _o -> {:error, :boom} end)

      assert {:ok, msg} = Handler.execute(%{"action" => "spawn", "task" => "x"}, ctx)
      assert msg =~ "Fleet spawn failed"
      assert msg =~ "boom"
    end

    test "unknown agent_type is forwarded as-is (registry default handles fallback)",
         %{ctx: ctx} do
      Effort.set(:low)
      test_pid = self()

      put_spawn(fn parent, opts ->
        send(test_pid, {:spawned, parent, opts})
        {:ok, "fleet:#{parent}:1"}
      end)

      # An unknown agent_type must NOT be an error at the tool boundary — it is
      # forwarded; the registry resolves unknown types to "general-purpose".
      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "spawn", "task" => "x", "agent_type" => "does-not-exist"},
                 ctx
               )

      assert msg =~ "Spawned full-power fleet node"
      assert_received {:spawned, _parent, opts}
      assert Keyword.get(opts, :agent_type) == "does-not-exist"
    end

    test "blank/omitted agent_type defaults to general-purpose", %{ctx: ctx} do
      Effort.set(:low)
      test_pid = self()

      put_spawn(fn parent, opts ->
        send(test_pid, {:spawned, parent, opts})
        {:ok, "fleet:#{parent}:1"}
      end)

      assert {:ok, _msg} =
               Handler.execute(%{"action" => "spawn", "task" => "x", "agent_type" => "  "}, ctx)

      assert_received {:spawned, _parent, opts}
      assert Keyword.get(opts, :agent_type) == "general-purpose"
    end
  end

  describe "execute/2 — workflow (ultra-gated)" do
    test "below ultra returns a clear raise-to-ultra message", %{ctx: ctx} do
      Effort.set(:high)
      put_spawn(fn _p, o -> {:ok, Keyword.get(o, :task)} end)

      assert {:ok, msg} =
               Handler.execute(%{"action" => "workflow", "items" => ["a", "b"]}, ctx)

      assert msg =~ "ultra-gated"
      assert msg =~ "ultra"
    end

    test "at ultra drains all items via the injected spawn fn", %{ctx: ctx} do
      Effort.set(:ultra)
      test_pid = self()

      put_spawn(fn _p, o ->
        send(test_pid, {:item, Keyword.get(o, :task), Keyword.get(o, :agent_type)})
        {:ok, Keyword.get(o, :task)}
      end)

      assert {:ok, msg} =
               Handler.execute(
                 %{
                   "action" => "workflow",
                   "items" => ["a", "b", "c"],
                   "agent_type" => "general-purpose",
                   "task" => "umbrella"
                 },
                 ctx
               )

      assert msg =~ "3 spawned OK, 0 failed"
      # Every item ran through the full-power path with the shared agent_type.
      for t <- ~w(a b c), do: assert_received({:item, ^t, "general-purpose"})
    end
  end

  describe "execute/2 — workflow isolation + finalize wiring" do
    test "isolation:true runs each item in its own worktree", %{ctx: ctx} do
      Effort.set(:ultra)
      test_pid = self()

      # Inject a fake worktree creator so no real git is touched; a non-existent
      # path means the default diff read is [] (fine — merge is mocked below).
      Application.put_env(:optimal_system_agent, :fleet_worktree_fun, fn _p, _o ->
        send(test_pid, :worktree_created)
        {:ok, %{path: "/tmp/no-such-#{System.unique_integer([:positive])}", branch: "br"}}
      end)

      on_exit(fn -> Application.delete_env(:optimal_system_agent, :fleet_worktree_fun) end)

      put_spawn(fn _p, o -> {:ok, Keyword.get(o, :task)} end)

      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "workflow", "items" => ["a", "b"], "isolation" => true},
                 ctx
               )

      assert msg =~ "2 spawned OK"
      # One worktree per item → isolation reached fan_out's isolated spawn path.
      assert_received :worktree_created
      assert_received :worktree_created
    end

    test "finalize:true with isolation calls the finalizer and folds its result in",
         %{ctx: ctx} do
      Effort.set(:ultra)
      test_pid = self()

      Application.put_env(:optimal_system_agent, :fleet_worktree_fun, fn _p, _o ->
        {:ok, %{path: "/tmp/wt-#{System.unique_integer([:positive])}", branch: "br"}}
      end)

      Application.put_env(:optimal_system_agent, :fleet_finalize_fun, fn parent, results, opts ->
        send(test_pid, {:finalized, parent, results, opts})
        %{merged: ["lib/a.ex"], conflicts: [], gate: :pass, gate_output: "", committed: true, message: "ok"}
      end)

      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :fleet_worktree_fun)
        Application.delete_env(:optimal_system_agent, :fleet_finalize_fun)
      end)

      put_spawn(fn _p, o -> {:ok, Keyword.get(o, :task)} end)

      assert {:ok, msg} =
               Handler.execute(
                 %{
                   "action" => "workflow",
                   "items" => ["a"],
                   "isolation" => true,
                   "finalize" => true,
                   "gate" => ["mix compile", "mix test"],
                   "commit_message" => "feat: land wave"
                 },
                 ctx
               )

      assert_received {:finalized, _parent, results, opts}
      assert is_list(results)
      assert Keyword.get(opts, :gate_cmds) == ["mix compile", "mix test"]
      assert Keyword.get(opts, :commit) == "feat: land wave"

      # The finalizer's outcome is folded into the tool's returned message.
      assert msg =~ "Finalize: merged 1 file(s)"
      assert msg =~ "no conflicts"
      assert msg =~ "gate pass"
      assert msg =~ "committed true"
    end

    test "finalize:true WITHOUT isolation is skipped (finalizer never called)",
         %{ctx: ctx} do
      Effort.set(:ultra)

      Application.put_env(:optimal_system_agent, :fleet_finalize_fun, fn _p, _r, _o ->
        raise "finalizer must not be called without isolation"
      end)

      on_exit(fn -> Application.delete_env(:optimal_system_agent, :fleet_finalize_fun) end)

      put_spawn(fn _p, o -> {:ok, Keyword.get(o, :task)} end)

      assert {:ok, msg} =
               Handler.execute(
                 %{"action" => "workflow", "items" => ["a"], "finalize" => true},
                 ctx
               )

      assert msg =~ "Finalize skipped"
      assert msg =~ "isolation: true"
    end

    test "workflow without finalize appends no finalize note", %{ctx: ctx} do
      Effort.set(:ultra)
      put_spawn(fn _p, o -> {:ok, Keyword.get(o, :task)} end)

      assert {:ok, msg} =
               Handler.execute(%{"action" => "workflow", "items" => ["a"]}, ctx)

      refute msg =~ "Finalize"
    end
  end
end
