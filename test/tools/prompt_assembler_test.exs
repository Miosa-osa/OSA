defmodule OptimalSystemAgent.Tools.PromptAssemblerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.{PromptAssembler, UseContext}

  defmodule LoadedTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "loaded_tool"
    def description, do: "loaded tool description"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule DeferredTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "deferred_tool"
    def description, do: "deferred tool description"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def should_defer?, do: true
    def search_hint, do: "do something deferred"
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule AlwaysLoadDeferredTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "always_load_deferred"
    def description, do: "deferred but always_load wins"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def should_defer?, do: true
    def always_load?, do: true
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  defmodule UnavailableTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "unavailable"
    def description, do: "should be filtered out"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def available?, do: false
    def execute(_input, _ctx), do: {:ok, "ok"}
  end

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  describe "partition/1" do
    test "splits loaded vs deferred" do
      {loaded, deferred} =
        PromptAssembler.partition([LoadedTool, DeferredTool])

      assert LoadedTool in loaded
      assert DeferredTool in deferred
    end

    test "always_load? overrides should_defer?" do
      {loaded, deferred} =
        PromptAssembler.partition([AlwaysLoadDeferredTool, DeferredTool])

      assert AlwaysLoadDeferredTool in loaded
      assert DeferredTool in deferred
    end
  end

  describe "assemble/3" do
    test "loaded section contains tool name and description", %{ctx: ctx} do
      {section, _deferred} =
        PromptAssembler.assemble([LoadedTool], ctx)

      assert section =~ "loaded_tool"
      assert section =~ "loaded tool description"
    end

    test "deferred names contain search_hint when present", %{ctx: ctx} do
      {_section, deferred} =
        PromptAssembler.assemble([DeferredTool], ctx)

      assert "deferred_tool — do something deferred" in deferred
    end

    test "filters out unavailable tools", %{ctx: ctx} do
      {section, deferred} =
        PromptAssembler.assemble([LoadedTool, UnavailableTool], ctx)

      refute section =~ "unavailable"
      refute "unavailable" in deferred
    end

    test "byte-deterministic across runs", %{ctx: ctx} do
      tools = [LoadedTool, DeferredTool]
      a = PromptAssembler.assemble(tools, ctx)
      b = PromptAssembler.assemble(tools, ctx)
      assert a == b
    end
  end
end
