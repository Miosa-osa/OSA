defmodule OptimalSystemAgent.Soul.StaticBaseInvalidationTest do
  @moduledoc """
  `Soul.static_base/0,1` caches the fully-rendered system prompt in
  `:persistent_term`, and `{{TOOL_DEFINITIONS}}` inside it is rendered from the
  LIVE tool set (`{Tools.Registry, :builtin_tools}` for the prose,
  `{Tools.Registry, :mcp_tools}` for the `<mcp-servers>` catalog and, in the
  `:native_tools` variant, `Registry.list_active/0` for the strip decision).

  The cache was invalidated in exactly one place — `Soul.load/0`, i.e. boot and
  explicit `Soul.reload/0`. Nothing invalidated it when the TOOL SET changed.

  That is not a hypothetical ordering: `MCP.Client.Manager` starts AFTER
  `Tools.Registry` (supervisors/infrastructure.ex) and its sessions connect
  asynchronously, so every MCP tool registers after boot. Plugin tools arrive
  later still, via `Plugins.Loader` → `Tools.Registry.register/1`. Whatever tool
  set happened to exist at the first `static_base/0` call was frozen into the
  model's system prompt for the life of the node.

  These tests pin the invalidation contract: a tool-set mutation must make the
  NEXT read of every cached variant re-render.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.Manager
  alias OptimalSystemAgent.Soul
  alias OptimalSystemAgent.Tools.Registry

  @builtin_key {Registry, :builtin_tools}
  @mcp_key {Registry, :mcp_tools}

  defmodule LateArrivingTool do
    @moduledoc false
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "late_arriving_tool"
    def description, do: "REGISTERED_AFTER_FIRST_RENDER marker text"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  setup do
    prev_builtin = :persistent_term.get(@builtin_key, %{})
    prev_mcp = :persistent_term.get(@mcp_key, %{})

    on_exit(fn ->
      :persistent_term.put(@builtin_key, prev_builtin)
      :persistent_term.put(@mcp_key, prev_mcp)
      # Drop the fake server from the manager's own state so a later republish
      # cannot resurrect it into the global mcp_tools map.
      try do
        Manager.reload()
      catch
        _, _ -> :ok
      end

      # Rebuild every cached variant from the restored tool set so this file
      # cannot leave a stale prompt behind for the rest of the suite.
      Soul.reload()
    end)

    Soul.reload()
    :ok
  end

  describe "a builtin tool that registers after the first render" do
    test "appears in the full static base" do
      before = Soul.static_base()
      refute before =~ "late_arriving_tool"

      put_builtin(LateArrivingTool)

      assert Soul.static_base() =~ "late_arriving_tool",
             "a tool registered after the first static_base/0 call never reaches the model: " <>
               "the prompt is cached in persistent_term and nothing invalidates it on a " <>
               "tool-set change."
    end

    test "appears in the lite static base" do
      _ = Soul.static_base(:lite)
      put_builtin(LateArrivingTool)

      # Non-core tools are deferred in :lite, so the name shows up in the
      # <system-reminder> block rather than as a full definition.
      assert Soul.static_base(:lite) =~ "late_arriving_tool"
    end
  end

  describe "MCP tools that connect after the first render" do
    test "appear in the <mcp-servers> catalog of the full static base" do
      before = Soul.static_base()
      refute before =~ "mcp__late_server__late_tool"

      put_mcp_catalog()

      assert Soul.static_base() =~ "mcp__late_server__late_tool",
             "the owner's MCP servers connect asynchronously AFTER boot; if the prompt " <>
               "cache is not invalidated they leave no trace in the prompt at all."
    end

    test "appear in the native-tools static base" do
      _ = Soul.static_base(:native_tools)

      put_mcp_catalog()

      assert Soul.static_base(:native_tools) =~ "mcp__late_server__late_tool"
    end
  end

  describe "the :native_tools strip decision" do
    test "is recomputed against the tool set that exists at read time" do
      # Render BOTH variants while the late tool is absent, so both are cached
      # against a tool set that is about to stop existing.
      _ = Soul.static_base()
      _ = Soul.static_base(:native_tools)

      # Now the tool exists and is ACTIVE, so it is carried natively and its
      # description must NOT be duplicated in the prose...
      put_builtin(LateArrivingTool)
      assert "late_arriving_tool" in Enum.map(Registry.list_active(), & &1.name)
      native = Soul.static_base(:native_tools)

      # ...while the FULL variant, which has no native channel, must still
      # describe it. If the cache is stale, neither variant knows the tool
      # exists and the two agree only by accident.
      assert Soul.static_base() =~ "REGISTERED_AFTER_FIRST_RENDER marker text",
             "the full base must describe a tool the request does not carry natively"

      refute native =~ "REGISTERED_AFTER_FIRST_RENDER marker text",
             "the native variant must strip the description of a tool the request " <>
               "carries natively — a decision that is only correct if it is computed " <>
               "against the tool set live at read time"
    end
  end

  describe "invalidate_static_base/0" do
    test "is idempotent and cheap to call repeatedly (no thundering herd)" do
      first = Soul.static_base()

      # A burst of invalidations — what 12 MCP servers reporting their tools
      # looks like — must not rebuild anything until something reads.
      Enum.each(1..50, fn _ -> Soul.invalidate_static_base() end)
      assert :persistent_term.get({Soul, :static_base}, nil) == nil

      assert Soul.static_base() == first
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Register through the real GenServer path — the same call `Plugins.Loader`
  # makes — so the test exercises production wiring, not a persistent_term poke.
  defp put_builtin(mod) do
    :ok = Registry.register(mod)
  end

  # Report tools the way a real MCP session does — `Manager.report_tools/2`,
  # the cast every ServerSession fires once its handshake completes. Enough
  # tools to trip `MCP.Virtualization` (default threshold 10) so they come back
  # DEFERRED, which is the owner's actual situation with 12 servers: the
  # `<mcp-servers>` catalog is then the only evidence in the prompt that the
  # server exists at all.
  defp put_mcp_catalog do
    schemas =
      for i <- 1..12 do
        name = if i == 1, do: "late_tool", else: "late_tool_#{i}"
        %{"name" => name, "description" => "arrived late", "inputSchema" => %{}}
      end

    Manager.report_tools("late_server", schemas)
    # The cast is asynchronous; a synchronous call behind it flushes the mailbox.
    _ = Manager.list_servers()

    assert Map.has_key?(:persistent_term.get(@mcp_key, %{}), "mcp__late_server__late_tool"),
           "precondition: the manager published the reported tools"
  end
end
