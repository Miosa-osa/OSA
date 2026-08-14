defmodule OptimalSystemAgent.Soul.ToolsSectionTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul.ToolsSection
  alias OptimalSystemAgent.Tools.{PromptAssembler, UseContext}

  @pt_key {OptimalSystemAgent.Tools.Registry, :builtin_tools}

  # ── Test doubles ─────────────────────────────────────────────────────────

  # A structured tool that exports prompt/1 with a cross-tool reference.
  defmodule DynamicTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "dynamic_tool"
    def description, do: "STATIC description — should not appear in assembled output"

    def prompt(_opts) do
      "Dynamic body referencing cross_tool_ref in its instructions."
    end

    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule DeferredWithHint do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "deferred_with_hint"
    def description, do: "a deferred tool"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def should_defer?, do: true
    def search_hint, do: "use this for hints"
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule DeferredNoHint do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "deferred_no_hint"
    def description, do: "another deferred tool, no hint"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def should_defer?, do: true
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule StaticTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "static_tool"
    def description, do: "static only — no prompt/1"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  # Helper: swap the :builtin_tools persistent_term key and restore on exit.
  defp with_tools(tools_map, fun) do
    original = :persistent_term.get(@pt_key, :__not_set__)
    :persistent_term.put(@pt_key, tools_map)

    try do
      fun.()
    after
      case original do
        :__not_set__ -> :persistent_term.erase(@pt_key)
        prev -> :persistent_term.put(@pt_key, prev)
      end
    end
  end

  # ── PromptAssembler integration ───────────────────────────────────────────

  describe "PromptAssembler.assemble/3 — dynamic prompt/1 callback" do
    setup do
      {:ok, ctx: UseContext.empty()}
    end

    test "uses prompt/1 over description/0 for structured tools", %{ctx: ctx} do
      {section, _deferred} = PromptAssembler.assemble([DynamicTool], ctx)

      assert section =~ "cross_tool_ref"
      refute section =~ "STATIC description"
    end

    test "falls back to description/0 when prompt/1 not exported", %{ctx: ctx} do
      {section, _deferred} = PromptAssembler.assemble([StaticTool], ctx)

      assert section =~ "static only — no prompt/1"
    end

    test "deferred tools appear in deferred_names, not in loaded section", %{ctx: ctx} do
      {section, deferred} =
        PromptAssembler.assemble([DynamicTool, DeferredWithHint], ctx)

      assert section =~ "dynamic_tool"
      refute section =~ "deferred_with_hint"
      assert Enum.any?(deferred, &String.starts_with?(&1, "deferred_with_hint"))
    end

    test "deferred name includes hint when search_hint is non-empty", %{ctx: ctx} do
      {_section, deferred} = PromptAssembler.assemble([DeferredWithHint], ctx)

      assert "deferred_with_hint — use this for hints" in deferred
    end

    test "deferred name is bare tool name when no search_hint", %{ctx: ctx} do
      {_section, deferred} = PromptAssembler.assemble([DeferredNoHint], ctx)

      assert "deferred_no_hint" in deferred
    end

    test "count of loaded sections matches non-deferred tools", %{ctx: ctx} do
      tools = [DynamicTool, StaticTool, DeferredWithHint]
      {section, deferred} = PromptAssembler.assemble(tools, ctx)

      # Loaded section contains one "## toolname" header per loaded tool.
      loaded_count =
        section
        |> String.split("## ")
        |> Enum.drop(1)
        |> length()

      assert loaded_count == 2
      assert length(deferred) == 1
    end
  end

  # ── Soul.ToolsSection.build/0 — end-to-end via persistent_term ───────────

  describe "ToolsSection.build/0" do
    test "returns nil when no builtin_tools are registered" do
      with_tools(%{}, fn ->
        assert is_nil(ToolsSection.build())
      end)
    end

    test "output starts with ## Available Tools header when tools present" do
      with_tools(%{"dynamic_tool" => DynamicTool, "static_tool" => StaticTool}, fn ->
        result = ToolsSection.build()
        assert is_binary(result)
        assert String.starts_with?(result, "## Available Tools")
      end)
    end

    test "dynamic prompt body (cross-tool refs) appears in output" do
      with_tools(%{"dynamic_tool" => DynamicTool}, fn ->
        result = ToolsSection.build()
        # "cross_tool_ref" comes from DynamicTool.prompt/1, not description/0
        assert result =~ "cross_tool_ref"
        refute result =~ "STATIC description"
      end)
    end

    test "deferred tools produce a <system-reminder> block" do
      with_tools(%{"dynamic_tool" => DynamicTool, "deferred_with_hint" => DeferredWithHint}, fn ->
        result = ToolsSection.build()
        assert is_binary(result)
        assert result =~ "<system-reminder>"
        assert result =~ "deferred_with_hint"
        assert result =~ "tool_search"
      end)
    end

    test "no <system-reminder> when all tools are active (non-deferred)" do
      with_tools(%{"dynamic_tool" => DynamicTool, "static_tool" => StaticTool}, fn ->
        result = ToolsSection.build()
        refute result =~ "<system-reminder>"
      end)
    end
  end

  # ── Real structured tools: file_edit references file_read by name ─────────

  describe "file_edit dynamic prompt contains file_read cross-tool reference" do
    test "file_edit.prompt/1 mentions the literal string 'file_read'" do
      ctx = UseContext.empty()

      {section, _deferred} =
        PromptAssembler.assemble(
          [
            OptimalSystemAgent.Tools.Builtins.FileEdit.Tool,
            OptimalSystemAgent.Tools.Builtins.FileRead.Tool
          ],
          ctx
        )

      # FileEdit.Prompt.render/1 resolves FileRead.Constants.tool_name() via
      # safe_ref — the literal "file_read" must appear in the assembled section.
      assert section =~ "file_read"
      # Confirms the dynamic prompt body is used, not a static stub. This used
      # to pin the word "surgical"; that word was retired with the routing
      # rewrite, so the marker is now the routing sentence — which is both
      # dynamic (it resolves `file_transform` through safe_ref) and load-bearing.
      assert section =~ "file_transform"
    end
  end
end
