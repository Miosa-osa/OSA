defmodule OptimalSystemAgent.Tools.LegacyAdapterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.{LegacyAdapter, UseContext}

  defmodule FlatTool do
    @behaviour OptimalSystemAgent.Tools.Behaviour
    def name, do: "flat_tool"
    def description, do: "single-file tool"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(input), do: {:ok, "flat: #{inspect(input)}"}
    def safety, do: :read_only
    def concurrent?, do: true
    def deferred?, do: false
  end

  defmodule StructuredTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "structured_tool"
    def description, do: "per-tool dir tool"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def read_only?(_input, _ctx), do: true
    def concurrency_safe?(_input, _ctx), do: true
    def execute(input, _ctx), do: {:ok, "structured: #{inspect(input)}"}
  end

  defmodule DenyingTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "denying"
    def description, do: "always denies"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def check_permissions(_input, _ctx), do: {:deny, "always denied"}
    def execute(_input, _ctx), do: {:ok, "should never reach"}
  end

  defmodule ValidatingTool do
    use OptimalSystemAgent.Tools.Behaviour
    def name, do: "validating"
    def description, do: "rejects bad input"
    def parameters, do: %{"type" => "object", "properties" => %{}}

    def validate_input(%{"required" => _} = i, _ctx), do: {:ok, i}
    def validate_input(_, _ctx), do: {:error, "missing required field", -32_602}

    def execute(input, _ctx), do: {:ok, "ok: #{inspect(input)}"}
  end

  setup do
    {:ok, ctx: UseContext.empty()}
  end

  describe "structured?/1" do
    test "true for tool with execute/2" do
      assert LegacyAdapter.structured?(StructuredTool)
    end

    test "false for tool with only execute/1" do
      refute LegacyAdapter.structured?(FlatTool)
    end

    test "false for unloadable module" do
      refute LegacyAdapter.structured?(NonExistentModule)
    end
  end

  describe "execute/3 — flat routing" do
    test "calls execute/1 on flat tool", %{ctx: ctx} do
      assert {:ok, "flat: %{\"x\" => 42}"} =
               LegacyAdapter.execute(FlatTool, %{"x" => 42}, ctx)
    end
  end

  describe "execute/3 — structured routing" do
    test "calls validate → check_permissions → execute on structured tool", %{ctx: ctx} do
      assert {:ok, "structured: %{\"y\" => \"hello\"}"} =
               LegacyAdapter.execute(StructuredTool, %{"y" => "hello"}, ctx)
    end

    test "deny short-circuits before execute", %{ctx: ctx} do
      assert {:error, "Permission denied: always denied"} =
               LegacyAdapter.execute(DenyingTool, %{}, ctx)
    end

    test "validation error short-circuits before check_permissions", %{ctx: ctx} do
      assert {:error, "missing required field"} =
               LegacyAdapter.execute(ValidatingTool, %{}, ctx)
    end

    test "valid input passes through", %{ctx: ctx} do
      assert {:ok, _} =
               LegacyAdapter.execute(ValidatingTool, %{"required" => true}, ctx)
    end
  end

  describe "concurrency_safe?/3" do
    test "structured callback wins for structured tools", %{ctx: ctx} do
      assert LegacyAdapter.concurrency_safe?(StructuredTool, %{}, ctx)
    end

    test "falls back to flat concurrent?/0 for flat tools", %{ctx: ctx} do
      assert LegacyAdapter.concurrency_safe?(FlatTool, %{}, ctx)
    end
  end

  describe "read_only?/3" do
    test "structured callback wins for structured tools", %{ctx: ctx} do
      assert LegacyAdapter.read_only?(StructuredTool, %{}, ctx)
    end

    test "derives from safety/0 for flat tools", %{ctx: ctx} do
      assert LegacyAdapter.read_only?(FlatTool, %{}, ctx)
    end
  end

  describe "normalize/1" do
    test "produces uniform shape for flat and structured tools" do
      flat = LegacyAdapter.normalize(FlatTool)
      structured = LegacyAdapter.normalize(StructuredTool)

      for desc <- [flat, structured] do
        assert is_map(desc)
        assert Map.has_key?(desc, :module)
        assert Map.has_key?(desc, :name)
        assert Map.has_key?(desc, :description)
        assert Map.has_key?(desc, :parameters)
        assert Map.has_key?(desc, :aliases)
        assert Map.has_key?(desc, :search_hint)
        assert Map.has_key?(desc, :should_defer?)
        assert Map.has_key?(desc, :always_load?)
      end

      refute flat.structured?
      assert structured.structured?
    end
  end
end
