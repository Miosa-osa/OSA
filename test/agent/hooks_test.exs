defmodule OptimalSystemAgent.Agent.HooksTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks

  setup do
    case Process.whereis(Hooks) do
      nil ->
        {:ok, %{available: false}}

      _pid ->
        # Snapshot the global hook registry; on exit remove anything this test
        # added (e.g. a {:block,…} hook) so it can't leak into other tests'
        # Hooks.run/2 and block their passthroughs under random ordering.
        baseline = hook_key_set()

        on_exit(fn ->
          for {event, name} <- MapSet.difference(hook_key_set(), baseline) do
            Hooks.unregister(event, name)
          end
        end)

        {:ok, %{available: true}}
    end
  end

  defp hook_key_set do
    Hooks.list_hooks()
    |> Enum.flat_map(fn {event, hooks} -> Enum.map(hooks, &{event, &1.name}) end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Built-in hooks existence
  # ---------------------------------------------------------------------------

  describe "built-in hooks" do
    @tag :hooks
    test "all 6 built-in hooks are registered", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      listing = Hooks.list_hooks()

      pre_names = listing |> Map.get(:pre_tool_use, []) |> Enum.map(& &1.name)
      post_names = listing |> Map.get(:post_tool_use, []) |> Enum.map(& &1.name)

      assert "security_check" in pre_names
      assert "spend_guard" in pre_names
      assert "mcp_cache" in pre_names

      assert "cost_tracker" in post_names
      assert "mcp_cache_post" in post_names
      assert "telemetry" in post_names
    end

    @tag :hooks
    test "spend_guard has higher priority (lower number) than security_check", %{
      available: available
    } do
      if not available, do: flunk("Hooks GenServer not running")

      listing = Hooks.list_hooks()
      pre_hooks = Map.get(listing, :pre_tool_use, [])

      spend = Enum.find(pre_hooks, &(&1.name == "spend_guard"))
      security = Enum.find(pre_hooks, &(&1.name == "security_check"))

      assert spend.priority < security.priority
    end

    @tag :hooks
    test "pre_tool_use hooks are sorted by priority", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      listing = Hooks.list_hooks()
      pre_hooks = Map.get(listing, :pre_tool_use, [])

      priorities = Enum.map(pre_hooks, & &1.priority)
      assert priorities == Enum.sort(priorities)
    end
  end

  # ---------------------------------------------------------------------------
  # Hook registration
  # ---------------------------------------------------------------------------

  describe "register/4" do
    @tag :hooks
    test "registers a hook and it appears in list_hooks", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      hook_fn = fn payload -> {:ok, payload} end
      :ok = Hooks.register(:post_tool_use, "test_register_hook", hook_fn, priority: 99)

      # register is a cast — give it a moment
      Process.sleep(50)

      listing = Hooks.list_hooks()
      post_hooks = Map.get(listing, :post_tool_use, [])
      names = Enum.map(post_hooks, & &1.name)
      assert "test_register_hook" in names
    end
  end

  # ---------------------------------------------------------------------------
  # Hook execution — passthrough (non-shell tools)
  # ---------------------------------------------------------------------------

  describe "run/2 passthrough" do
    @tag :hooks
    test "returns {:ok, payload} for safe file_read tool", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{
        tool_name: "file_read",
        arguments: %{"path" => "/tmp/safe.txt"},
        session_id: "test"
      }

      result = Hooks.run(:pre_tool_use, payload)
      assert {:ok, returned_payload} = result
      assert returned_payload.tool_name == "file_read"
    end

    @tag :hooks
    test "returns {:ok, payload} for file_grep tool", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{tool_name: "file_grep", arguments: %{"query" => "hello"}, session_id: "test"}
      result = Hooks.run(:pre_tool_use, payload)
      assert {:ok, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Security check — blocking dangerous commands
  # ---------------------------------------------------------------------------

  describe "security_check blocking" do
    @tag :hooks
    test "blocks rm -rf /", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{
        tool_name: "shell_execute",
        arguments: %{"command" => "rm -rf /"},
        session_id: "test"
      }

      result = Hooks.run(:pre_tool_use, payload)
      assert {:blocked, reason} = result
      assert is_binary(reason)
    end

    @tag :hooks
    test "passes safe echo command", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{
        tool_name: "shell_execute",
        arguments: %{"command" => "echo hello"},
        session_id: "test"
      }

      result = Hooks.run(:pre_tool_use, payload)
      assert {:ok, _} = result
    end

    @tag :hooks
    test "passes non-shell tools through security_check", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{
        tool_name: "file_read",
        arguments: %{"path" => "/etc/passwd"},
        session_id: "test"
      }

      result = Hooks.run(:pre_tool_use, payload)
      assert {:ok, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Post-tool hooks
  # ---------------------------------------------------------------------------

  describe "run/2 post_tool_use" do
    @tag :hooks
    test "post_tool_use returns {:ok, payload}", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{tool_name: "file_read", result: "contents", duration_ms: 10, session_id: "test"}
      result = Hooks.run(:post_tool_use, payload)
      assert {:ok, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Async hooks
  # ---------------------------------------------------------------------------

  describe "run_async/2" do
    @tag :hooks
    test "returns :ok immediately", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      payload = %{tool_name: "test", result: "ok", duration_ms: 10, session_id: "test"}
      assert :ok = Hooks.run_async(:post_tool_use, payload)
    end
  end

  # ---------------------------------------------------------------------------
  # Crash isolation
  # ---------------------------------------------------------------------------

  describe "crash isolation" do
    @tag :hooks
    test "a crashing post_tool_use hook does not crash the pipeline", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      Hooks.register(
        :post_tool_use,
        "crasher_hook",
        fn _payload ->
          raise "kaboom"
        end,
        priority: 1
      )

      Process.sleep(50)

      payload = %{tool_name: "test", result: "ok", duration_ms: 10, session_id: "test"}
      result = Hooks.run(:post_tool_use, payload)
      assert {:ok, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Metrics
  # ---------------------------------------------------------------------------

  describe "metrics/0" do
    @tag :hooks
    test "returns a map", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      metrics = Hooks.metrics()
      assert is_map(metrics)
    end

    @tag :hooks
    test "metrics track calls after running hooks", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      Hooks.run(:pre_tool_use, %{
        tool_name: "file_read",
        arguments: %{},
        session_id: "metric_test"
      })

      metrics = Hooks.metrics()
      pre_metrics = Map.get(metrics, :pre_tool_use)

      if pre_metrics do
        assert pre_metrics.calls > 0
        assert pre_metrics.total_us >= 0
        assert Map.has_key?(pre_metrics, :avg_us)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Custom blocking hook — LAST to avoid polluting other tests
  # (no unregister API, so this MUST be the last describe block)
  # ---------------------------------------------------------------------------

  describe "custom hook blocking (runs last)" do
    @tag :hooks
    test "a registered hook returning {:block, reason} stops the chain", %{available: available} do
      if not available, do: flunk("Hooks GenServer not running")

      # Use a conditional blocker so it only blocks a specific tool name,
      # preventing pollution of other pre_tool_use tests (no unregister API).
      Hooks.register(
        :pre_tool_use,
        "final_test_blocker",
        fn payload ->
          if payload.tool_name == "blocked_test_tool" do
            {:block, "custom block reason"}
          else
            {:ok, payload}
          end
        end,
        priority: 1
      )

      Process.sleep(50)

      payload = %{tool_name: "blocked_test_tool", arguments: %{}, session_id: "test"}
      result = Hooks.run(:pre_tool_use, payload)
      assert {:blocked, "custom block reason"} = result
    end
  end
end
