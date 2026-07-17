# Test Patterns

Concrete patterns for common OSA test scenarios: testing GenServers, testing event
handlers, testing tool execution, and writing integration tests.

## Audience

Developers writing tests for OSA modules or ensuring new code is testable.

---

## Pattern 1: Testing a Pure Module (No GenServer)

Use this pattern for modules with no GenServer state — tools, providers, utilities.

```elixir
defmodule OptimalSystemAgent.Tools.Builtins.DiffTest do
  use ExUnit.Case, async: true  # Safe to parallelize

  alias OptimalSystemAgent.Tools.Builtins.Diff

  test "module exports the tool behaviour callbacks" do
    assert function_exported?(Diff, :name, 0)
    assert function_exported?(Diff, :description, 0)
    assert function_exported?(Diff, :parameters, 0)
    assert function_exported?(Diff, :execute, 1)
  end

  test "name returns a string" do
    assert is_binary(Diff.name())
  end

  test "parameters returns a valid JSON schema object" do
    params = Diff.parameters()
    assert is_map(params)
    assert params["type"] == "object"
    assert is_map(params["properties"])
  end

  test "execute with valid args returns ok tuple" do
    result = Diff.execute(%{"original" => "hello", "modified" => "hello world"})
    assert {:ok, _output} = result
  end

  test "execute with missing required arg returns error tuple" do
    result = Diff.execute(%{})
    assert {:error, _reason} = result
  end
end
```

---

## Pattern 2: Testing a GenServer in Isolation

Use `start_supervised!/2` to start the process under the test's supervisor.
ExUnit cleans it up after the test, preventing state leaks.

```elixir
defmodule OptimalSystemAgent.MyFeatureTest do
  use ExUnit.Case, async: false  # async: false for named processes

  alias OptimalSystemAgent.MyFeature

  setup do
    # Start the GenServer fresh for each test.
    # start_supervised! terminates it automatically after the test.
    start_supervised!(MyFeature)
    :ok
  end

  test "get_cached_data returns empty map initially" do
    assert MyFeature.get_cached_data() == %{}
  end

  test "update_data stores and retrieves values" do
    :ok = MyFeature.update_data(%{key: "value"})
    assert MyFeature.get_cached_data() == %{key: "value"}
  end

  test "concurrent reads are safe" do
    # Write some data:
    :ok = MyFeature.update_data(%{x: 1})

    # Read from multiple concurrent tasks:
    tasks = Enum.map(1..10, fn _ ->
      Task.async(fn -> MyFeature.get_cached_data() end)
    end)

    results = Task.await_many(tasks)
    Enum.each(results, fn result ->
      assert result == %{x: 1}
    end)
  end
end
```

---

## Pattern 3: Testing Agent Sessions (Loop)

Based on the approach in `test/agent/loop_test.exs`:

```elixir
defmodule OptimalSystemAgent.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop

  # Generate unique session IDs to prevent collisions between test runs
  defp unique_session_id do
    "test-loop-#{:erlang.unique_integer([:positive])}"
  end

  setup do
    # Ensure Registry is running — start it if not, skip if it is
    case Process.whereis(OptimalSystemAgent.SessionRegistry) do
      nil ->
        start_supervised!(
          {Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry}
        )
      _pid ->
        :ok
    end
    :ok
  end

  test "starts a session GenServer" do
    session_id = unique_session_id()

    pid = start_supervised!(
      {Loop, [session_id: session_id, channel: :cli]},
      id: String.to_atom(session_id)
    )

    assert Process.alive?(pid)
  end

  test "registers session in the SessionRegistry" do
    session_id = unique_session_id()

    start_supervised!(
      {Loop, [session_id: session_id, channel: :cli]},
      id: String.to_atom(session_id)
    )

    assert [{_pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
  end

  test "get_owner returns the registered owner" do
    session_id = unique_session_id()
    start_supervised!(
      {Loop, [session_id: session_id, channel: :cli, owner: "test@example.com"]},
      id: String.to_atom(session_id)
    )

    owner = Loop.get_owner(session_id)
    assert owner == "test@example.com"
  end
end
```

---

## Pattern 4: Testing Hook Registration and Execution

Based on `test/agent/hooks_test.exs`:

```elixir
defmodule OptimalSystemAgent.Agent.HooksTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks

  # Check availability but don't fail if server not running — skip gracefully.
  setup do
    case Process.whereis(Hooks) do
      nil -> {:ok, %{available: false}}
      _pid -> {:ok, %{available: true}}
    end
  end

  @tag :hooks
  test "registers a hook and it appears in list_hooks", %{available: available} do
    if not available, do: flunk("Hooks GenServer not running")

    hook_fn = fn payload -> {:ok, payload} end
    :ok = Hooks.register(:post_tool_use, "my_test_hook", hook_fn, priority: 99)

    # register/4 is a GenServer.cast — wait for it to be processed
    Process.sleep(50)

    listing = Hooks.list_hooks()
    post_hooks = Map.get(listing, :post_tool_use, [])
    assert Enum.any?(post_hooks, &(&1.name == "my_test_hook"))
  end

  @tag :hooks
  test "pre_tool_use returns {:ok, payload} for safe tool" do
    if not available, do: flunk("Hooks GenServer not running")

    payload = %{
      tool_name: "file_read",
      arguments: %{"path" => "/tmp/safe.txt"},
      session_id: "test"
    }
    assert {:ok, returned} = Hooks.run(:pre_tool_use, payload)
    assert returned.tool_name == "file_read"
  end

  @tag :hooks
  test "blocks dangerous shell commands" do
    if not available, do: flunk("Hooks GenServer not running")

    payload = %{
      tool_name: "shell_execute",
      arguments: %{"command" => "rm -rf /"},
      session_id: "test"
    }
    assert {:blocked, reason} = Hooks.run(:pre_tool_use, payload)
    assert is_binary(reason)
  end

  @tag :hooks
  test "a crashing hook does not crash the pipeline" do
    if not available, do: flunk("Hooks GenServer not running")

    Hooks.register(:post_tool_use, "crasher", fn _p -> raise "kaboom" end, priority: 1)
    Process.sleep(50)

    payload = %{tool_name: "file_read", result: "ok", duration_ms: 5, session_id: "test"}
    assert {:ok, _} = Hooks.run(:post_tool_use, payload)
  end
end
```

---

## Pattern 5: Testing Event Handlers

```elixir
defmodule EventHandlerTest do
  use ExUnit.Case, async: false

  test "registered handler receives emitted events" do
    test_pid = self()

    ref = OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn event ->
      send(test_pid, {:got_event, event})
    end)

    OptimalSystemAgent.Events.Bus.emit(
      :system_event,
      %{event: :test_payload},
      source: "test",
      session_id: "test-session"
    )

    # Handlers run in supervised Tasks — assert_receive with timeout
    assert_receive {:got_event, event}, 500
    assert event[:type] == :system_event
    assert event[:source] == "test"

    # Clean up
    OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref)
  end

  test "handler does not receive events after unregistration" do
    test_pid = self()

    ref = OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn _event ->
      send(test_pid, :should_not_receive)
    end)

    OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref)

    OptimalSystemAgent.Events.Bus.emit(:system_event, %{event: :ignored})

    refute_receive :should_not_receive, 200
  end
end
```

---

## Pattern 6: Testing Tool Schema Validation

Based on `test/tools/schema_validation_test.exs`:

```elixir
defmodule SchemaValidationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Registry

  # Define inline test tool modules:
  defmodule StrictTool do
    @behaviour MiosaTools.Behaviour
    def name, do: "strict_tool"
    def description, do: "requires query"
    def safety, do: :read_only
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
        },
        "required" => ["query"]
      }
    end
    def execute(%{"query" => q}), do: {:ok, q}
  end

  test "valid args pass validation" do
    assert :ok = Registry.validate_arguments(StrictTool, %{"query" => "test"})
  end

  test "missing required arg fails with descriptive error" do
    assert {:error, message} = Registry.validate_arguments(StrictTool, %{})
    assert message =~ "strict_tool"
    assert message =~ "query"
  end

  test "wrong type fails validation" do
    assert {:error, message} =
             Registry.validate_arguments(StrictTool, %{"query" => "ok", "limit" => "not_int"})
    assert message =~ "limit"
  end

  test "extra fields are allowed (not strict)" do
    # JSON Schema does not block additionalProperties by default
    assert :ok = Registry.validate_arguments(StrictTool, %{
      "query" => "test",
      "unexpected_field" => true
    })
  end
end
```

---

## Pattern 7: Testing Middleware Stacks

Based on `test/tools/middleware_test.exs`:

```elixir
defmodule MiddlewareTest do
  use ExUnit.Case, async: true

  alias MiosaTools.{Instruction, Middleware}

  defp ok_executor(instruction) do
    {:ok, instruction.params}
  end

  test "middleware runs in order" do
    defmodule FirstMW do
      @behaviour Middleware
      @impl true
      def call(inst, next, _opts) do
        updated = %{inst | params: Map.put(inst.params, :order, [:first])}
        case next.(updated) do
          {:ok, result} -> {:ok, Map.update(result, :order, [:first], &([:first | &1]))}
          err -> err
        end
      end
    end

    inst = %Instruction{tool: "test", params: %{}}
    assert {:ok, result} = Middleware.execute(inst, [FirstMW], &ok_executor/1)
    assert :first in result[:order]
  end

  test "blocking middleware prevents executor from running" do
    executed? = :atomics.new(1, [])

    executor = fn _inst ->
      :atomics.add(executed?, 1, 1)
      {:ok, %{}}
    end

    defmodule BlockMW do
      @behaviour Middleware
      @impl true
      def call(_inst, _next, _opts), do: {:error, "blocked"}
    end

    inst = %Instruction{tool: "test", params: %{}}
    assert {:error, "blocked"} = Middleware.execute(inst, [BlockMW], executor)
    assert :atomics.get(executed?, 1) == 0
  end
end
```

---

## Pattern 8: Integration Tests for HTTP Endpoints

```elixir
defmodule OptimalSystemAgent.HTTPEndpointTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @base_url "http://localhost:9089"

  test "GET /health returns 200" do
    assert {:ok, %{status: 200, body: body}} =
             Req.get("#{@base_url}/health")
    assert is_map(body)
    assert Map.has_key?(body, "status")
  end

  test "GET /api/v1/tools returns tool list" do
    assert {:ok, %{status: 200, body: body}} =
             Req.get("#{@base_url}/api/v1/tools",
               headers: [{"Authorization", "Bearer #{test_token()}"}]
             )
    assert is_list(body)
    assert length(body) > 0
  end

  defp test_token do
    # Generate a test JWT or use a configured dev token
    Application.get_env(:optimal_system_agent, :dev_token, "dev-token")
  end
end
```

Tag integration tests with `@moduletag :integration` so they are excluded by default
(they require a running server). Run with `mix test --include integration`.
