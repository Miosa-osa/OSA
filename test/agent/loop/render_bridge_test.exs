defmodule OptimalSystemAgent.Agent.Loop.RenderBridgeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.RenderBridge
  alias OptimalSystemAgent.Events.Bus

  # ── Stub tool modules ──────────────────────────────────────────────────────

  # A tool with a working render/3 that returns a proper map.
  defmodule GoodRenderTool do
    def name, do: "good_render_tool"

    def render(:tool_result, _payload, _opts), do: %{kind: "good_result", bytes: 42}
    def render(:error, msg, _opts), do: %{kind: "good_error", message: msg}
    def render(:rejected, _payload, _opts), do: %{kind: "good_rejected"}
    def render(_stage, _payload, _opts), do: nil
  end

  # A tool whose render/3 always raises.
  defmodule CrashingRenderTool do
    def name, do: "crashing_render_tool"

    def render(_stage, _payload, _opts) do
      raise "intentional crash in render/3"
    end
  end

  # A tool whose render/3 exits (process-level signal).
  defmodule ExitRenderTool do
    def name, do: "exit_render_tool"

    def render(_stage, _payload, _opts) do
      exit(:simulated_exit)
    end
  end

  # A tool whose render/3 always returns nil.
  defmodule NilRenderTool do
    def name, do: "nil_render_tool"

    def render(_stage, _payload, _opts), do: nil
  end

  # ── Test helpers ───────────────────────────────────────────────────────────

  # Seed the persistent_term registry so RenderBridge.lookup_module/1 finds
  # test stubs without needing the full Tools.Registry GenServer.
  defp seed_registry(name_to_mod) do
    existing =
      :persistent_term.get(
        {OptimalSystemAgent.Tools.Registry, :builtin_tools},
        %{}
      )

    :persistent_term.put(
      {OptimalSystemAgent.Tools.Registry, :builtin_tools},
      Map.merge(existing, name_to_mod)
    )
  end

  # Subscribe to Bus :tool_render events for a specific session_id only.
  # Filters at handler level so stale events from other tests are silently
  # dropped. The Bus dispatches async — handler isolation prevents cross-test
  # mailbox contamination under random test ordering.
  defp subscribe_for_session(test_pid, session_id, tag \\ :bus_event) do
    Bus.register_handler(:tool_render, fn event_map ->
      data = event_map[:data] || event_map["data"]

      if is_map(data) and data[:session_id] == session_id do
        send(test_pid, {tag, event_map})
      end
    end)
  end

  setup do
    seed_registry(%{
      "good_render_tool" => GoodRenderTool,
      "crashing_render_tool" => CrashingRenderTool,
      "nil_render_tool" => NilRenderTool,
      "exit_render_tool" => ExitRenderTool
    })

    :ok
  end

  # ── Success path ───────────────────────────────────────────────────────────

  describe "emit/3 — success result" do
    test "emits :tool_render event; render map is in the event data field" do
      session_id = "test-session-success-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id, :tool_render_received)

      RenderBridge.emit("good_render_tool", {:ok, "file content"}, session_id)

      assert_receive {:tool_render_received, event_map}, 2000

      data = event_map[:data] || event_map["data"]
      assert is_map(data)
      assert data[:tool_name] == "good_render_tool"
      assert data[:stage] == :tool_result
      assert data[:session_id] == session_id
      assert data[:kind] == "good_result"
      assert data[:bytes] == 42

      Bus.unregister_handler(:tool_render, ref)
    end

    test "emits :tool_render with :tool_result stage for {:ok, content} result" do
      session_id = "test-session-ok-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id)

      RenderBridge.emit("good_render_tool", {:ok, "hello"}, session_id)

      assert_receive {:bus_event, event_map}, 2000
      data = event_map[:data] || event_map["data"]
      assert data[:stage] == :tool_result

      Bus.unregister_handler(:tool_render, ref)
    end

    test "emits :tool_render with :tool_result stage for {:ok, content, metadata} result" do
      session_id = "test-session-meta-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id)

      RenderBridge.emit("good_render_tool", {:ok, "hello", %{diff: "..."}}, session_id)

      assert_receive {:bus_event, event_map}, 2000
      data = event_map[:data] || event_map["data"]
      assert data[:stage] == :tool_result

      Bus.unregister_handler(:tool_render, ref)
    end
  end

  # ── Error path ─────────────────────────────────────────────────────────────

  describe "emit/3 — error result" do
    test "maps {:error, reason} to :error stage" do
      session_id = "test-session-err-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id)

      RenderBridge.emit("good_render_tool", {:error, "file not found"}, session_id)

      assert_receive {:bus_event, event_map}, 2000
      data = event_map[:data] || event_map["data"]
      assert data[:stage] == :error
      assert data[:kind] == "good_error"

      Bus.unregister_handler(:tool_render, ref)
    end

    test "maps 'Error: ...' binary string to :error stage" do
      session_id = "test-session-errbinary-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id)

      RenderBridge.emit("good_render_tool", "Error: something went wrong", session_id)

      assert_receive {:bus_event, event_map}, 2000
      data = event_map[:data] || event_map["data"]
      assert data[:stage] == :error

      Bus.unregister_handler(:tool_render, ref)
    end
  end

  # ── Rejected path ──────────────────────────────────────────────────────────

  describe "emit/3 — rejected (permission blocked)" do
    test "maps 'Blocked: ...' binary string to :rejected stage" do
      session_id = "test-session-blocked-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id)

      RenderBridge.emit(
        "good_render_tool",
        "Blocked: read_only mode denies this tool",
        session_id
      )

      assert_receive {:bus_event, event_map}, 2000
      data = event_map[:data] || event_map["data"]
      assert data[:stage] == :rejected
      assert data[:kind] == "good_rejected"

      Bus.unregister_handler(:tool_render, ref)
    end
  end

  # ── Fail-soft paths ────────────────────────────────────────────────────────

  describe "emit/3 — fail-soft guarantees" do
    test "does not raise when render/3 crashes — returns :ok" do
      assert :ok = RenderBridge.emit("crashing_render_tool", {:ok, "content"}, "s1")
    end

    test "does not raise when render/3 throws an exit — returns :ok" do
      assert :ok = RenderBridge.emit("exit_render_tool", {:ok, "content"}, "s3")
    end

    test "does not raise when tool_name is unknown (not in registry) — returns :ok" do
      assert :ok = RenderBridge.emit("completely_unknown_tool_xyz", {:ok, "content"}, "s2")
    end

    test "does not raise when session_id is nil — returns :ok" do
      assert :ok = RenderBridge.emit("good_render_tool", {:ok, "content"}, nil)
    end

    test "does not emit Bus event when render/3 returns nil — no message received" do
      session_id = "test-session-nil-#{System.unique_integer()}"
      ref = subscribe_for_session(self(), session_id)

      assert :ok = RenderBridge.emit("nil_render_tool", {:ok, "content"}, session_id)

      # subscribe_for_session filters on session_id, so only events for this
      # exact session would arrive. Assert none do within 300ms.
      refute_receive {:bus_event, _}, 300

      Bus.unregister_handler(:tool_render, ref)
    end
  end
end
