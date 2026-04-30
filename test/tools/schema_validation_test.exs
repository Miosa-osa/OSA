defmodule OptimalSystemAgent.Tools.SchemaValidationTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Registry

  # ---------------------------------------------------------------------------
  # Test tool module with a strict JSON Schema
  # ---------------------------------------------------------------------------

  defmodule FakeTool do
    @behaviour OptimalSystemAgent.Tools.Behaviour

    @impl true
    def name, do: "fake_tool"

    @impl true
    def description, do: "A fake tool for testing schema validation"

    @impl true
    def safety, do: :read_only

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"},
          "limit" => %{"type" => "integer", "description" => "Max results"},
          "verbose" => %{"type" => "boolean", "description" => "Verbose output"}
        },
        "required" => ["query"]
      }
    end

    @impl true
    def execute(%{"query" => query}) do
      {:ok, "results for: #{query}"}
    end
  end

  # A tool with no required fields (should accept empty map)
  defmodule OptionalTool do
    @behaviour OptimalSystemAgent.Tools.Behaviour

    @impl true
    def name, do: "optional_tool"

    @impl true
    def description, do: "Tool with only optional params"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "tag" => %{"type" => "string"}
        }
      }
    end

    @impl true
    def execute(_args), do: {:ok, "ok"}
  end

  defmodule BrokenReadOnlyTool do
    def name, do: "broken_read_only"
    def description, do: "Read-only tool with broken schema"
    def safety, do: :read_only
    def parameters, do: raise("schema unavailable")
    def execute(_args), do: {:ok, "ok"}
  end

  defmodule BrokenWriteTool do
    def name, do: "broken_write"
    def description, do: "Mutating tool with broken schema"
    def safety, do: :write_safe
    def parameters, do: raise("schema unavailable")
    def execute(_args), do: {:ok, "ok"}
  end

  defmodule BrokenTerminalTool do
    def name, do: "broken_terminal"
    def description, do: "Terminal tool with broken schema"
    def safety, do: :terminal
    def parameters, do: raise("schema unavailable")
    def execute(_args), do: {:ok, "ok"}
  end

  defmodule BrokenActionTool do
    def name, do: "broken_action"
    def description, do: "Action-classified tool with broken schema"
    def parameters, do: raise("schema unavailable")
    def read_only?(%{"action" => "list"}, _ctx), do: true
    def read_only?(_input, _ctx), do: false
    def destructive?(%{"action" => "delete"}, _ctx), do: true
    def destructive?(_input, _ctx), do: false
    def execute(_args), do: {:ok, "ok"}
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — valid args
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with valid args" do
    test "should pass when all required args present with correct types" do
      args = %{"query" => "hello", "limit" => 10}
      assert :ok = Registry.validate_arguments(FakeTool, args)
    end

    test "should pass when only required args present" do
      args = %{"query" => "hello"}
      assert :ok = Registry.validate_arguments(FakeTool, args)
    end

    test "should pass when all args present with correct types" do
      args = %{"query" => "hello", "limit" => 5, "verbose" => true}
      assert :ok = Registry.validate_arguments(FakeTool, args)
    end

    test "should pass with empty map when no required fields" do
      assert :ok = Registry.validate_arguments(OptionalTool, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — missing required args
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with missing required args" do
    test "should return error when required arg is missing" do
      args = %{"limit" => 10}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end

    test "should return error with empty map when required fields exist" do
      assert {:error, message} = Registry.validate_arguments(FakeTool, %{})
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — wrong types
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with wrong types" do
    test "should return error when string arg receives integer" do
      args = %{"query" => 12345}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end

    test "should return error when integer arg receives string" do
      args = %{"query" => "hello", "limit" => "not_a_number"}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end

    test "should return error when boolean arg receives string" do
      args = %{"query" => "hello", "verbose" => "yes"}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end
  end

  # ---------------------------------------------------------------------------
  # safety/0 callback
  # ---------------------------------------------------------------------------

  describe "safety/0 callback" do
    test "should return :read_only for FileRead" do
      assert OptimalSystemAgent.Tools.Builtins.FileRead.safety() == :read_only
    end

    test "should return :write_safe for FileWrite" do
      assert OptimalSystemAgent.Tools.Builtins.FileWrite.safety() == :write_safe
    end

    test "should return :terminal for ShellExecute" do
      assert OptimalSystemAgent.Tools.Builtins.ShellExecute.safety() == :terminal
    end

    test "should return :write_safe for Git" do
      assert OptimalSystemAgent.Tools.Builtins.Git.safety() == :write_safe
    end

    test "should return :read_only for FakeTool" do
      assert FakeTool.safety() == :read_only
    end
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — real tool schemas
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with real tool modules" do
    test "should validate file_read args correctly" do
      mod = OptimalSystemAgent.Tools.Builtins.FileRead
      assert :ok = Registry.validate_arguments(mod, %{"path" => "/tmp/test.txt"})
    end

    test "should reject file_read with missing path" do
      mod = OptimalSystemAgent.Tools.Builtins.FileRead
      assert {:error, msg} = Registry.validate_arguments(mod, %{})
      assert msg =~ "validation failed"
    end

    test "should reject shell_execute with wrong type for command" do
      mod = OptimalSystemAgent.Tools.Builtins.ShellExecute
      assert {:error, msg} = Registry.validate_arguments(mod, %{"command" => 42})
      assert msg =~ "validation failed"
    end
  end

  describe "validate_arguments/2 when validation infrastructure fails" do
    test "fails open for confidently read-only tools" do
      assert :ok = Registry.validate_arguments(BrokenReadOnlyTool, %{"query" => "safe"})
    end

    test "fails closed for mutating tools" do
      assert {:error, message} = Registry.validate_arguments(BrokenWriteTool, %{"path" => "x"})
      assert message =~ "broken_write"
      assert message =~ "validation unavailable"
    end

    test "fails closed for terminal or destructive tools" do
      assert {:error, message} =
               Registry.validate_arguments(BrokenTerminalTool, %{"command" => "echo ok"})

      assert message =~ "broken_terminal"
      assert message =~ "validation unavailable"
    end

    test "uses per-input read_only?/destructive? classification" do
      assert :ok = Registry.validate_arguments(BrokenActionTool, %{"action" => "list"})

      assert {:error, message} =
               Registry.validate_arguments(BrokenActionTool, %{"action" => "delete"})

      assert message =~ "broken_action"
      assert message =~ "validation unavailable"
    end
  end
end
