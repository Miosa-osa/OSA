defmodule OptimalSystemAgent.Tools.InstructionTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Instruction

  # ---------------------------------------------------------------------------
  # Normalization from string
  # ---------------------------------------------------------------------------

  describe "normalize/1 with string input" do
    test "normalizes a bare tool name" do
      assert {:ok, %Instruction{tool: "file_read", params: %{}, context: %{}}} =
               Instruction.normalize("file_read")
    end

    test "rejects an empty string" do
      assert {:error, msg} = Instruction.normalize("")
      assert msg =~ "cannot be empty"
    end

    test "rejects a whitespace-only string" do
      assert {:error, _} = Instruction.normalize("   ")
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization from 2-tuple
  # ---------------------------------------------------------------------------

  describe "normalize/1 with {tool, params} tuple" do
    test "normalizes tool name with params" do
      input = {"file_read", %{"path" => "/tmp/file.txt"}}

      assert {:ok,
              %Instruction{tool: "file_read", params: %{"path" => "/tmp/file.txt"}, context: %{}}} =
               Instruction.normalize(input)
    end

    test "rejects non-map params" do
      assert {:error, _} = Instruction.normalize({"file_read", "not a map"})
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization from 3-tuple
  # ---------------------------------------------------------------------------

  describe "normalize/1 with {tool, params, context} tuple" do
    test "normalizes tool name with params and context" do
      input = {"file_read", %{"path" => "/tmp"}, %{user: "admin"}}

      assert {:ok,
              %Instruction{
                tool: "file_read",
                params: %{"path" => "/tmp"},
                context: %{user: "admin"}
              }} = Instruction.normalize(input)
    end

    test "rejects non-map context" do
      assert {:error, _} = Instruction.normalize({"file_read", %{}, "not a map"})
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization from struct (passthrough)
  # ---------------------------------------------------------------------------

  describe "normalize/1 with %Instruction{}" do
    test "passes through a valid struct" do
      inst = %Instruction{tool: "file_read", params: %{"path" => "/x"}}
      assert {:ok, ^inst} = Instruction.normalize(inst)
    end

    test "passes through a struct with empty tool (no content validation)" do
      inst = %Instruction{tool: ""}
      assert {:ok, ^inst} = Instruction.normalize(inst)
    end
  end

  # ---------------------------------------------------------------------------
  # Unsupported inputs
  # ---------------------------------------------------------------------------

  describe "normalize/1 with unsupported input" do
    test "rejects an integer" do
      assert {:error, msg} = Instruction.normalize(42)
      assert msg =~ "unsupported"
    end

    test "rejects a list" do
      assert {:error, _} = Instruction.normalize(["file_read"])
    end

    test "rejects nil" do
      assert {:error, _} = Instruction.normalize(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # normalize!/1
  # ---------------------------------------------------------------------------

  describe "normalize!/1" do
    test "returns the struct on valid input" do
      assert %Instruction{tool: "test"} = Instruction.normalize!("test")
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        Instruction.normalize!(42)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # merge_params/2
  # ---------------------------------------------------------------------------

  describe "merge_params/2" do
    test "merges new params into existing" do
      inst = %Instruction{tool: "test", params: %{a: 1, b: 2}}
      merged = Instruction.merge_params(inst, %{b: 3, c: 4})
      assert merged.params == %{a: 1, b: 3, c: 4}
    end

    test "preserves tool and context" do
      inst = %Instruction{tool: "test", params: %{}, context: %{x: 1}}
      merged = Instruction.merge_params(inst, %{a: 1})
      assert merged.tool == "test"
      assert merged.context == %{x: 1}
    end
  end
end
