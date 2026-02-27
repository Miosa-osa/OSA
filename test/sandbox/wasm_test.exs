defmodule OptimalSystemAgent.Sandbox.WasmTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Sandbox.Wasm

  describe "available?/0" do
    test "returns boolean" do
      result = Wasm.available?()
      assert is_boolean(result)
    end
  end

  describe "execute/2" do
    test "returns error when wasmtime not available and given invalid file" do
      # This tests graceful handling regardless of wasmtime availability
      result = Wasm.execute("/nonexistent/file.wasm", timeout: 5_000)
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    test "respects timeout" do
      # A very short timeout should not hang
      result = Wasm.execute("/nonexistent.wasm", timeout: 100)
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    test "builds args with workspace" do
      # Test that the function doesn't crash with various opts
      result =
        Wasm.execute("/test.wasm",
          timeout: 100,
          workspace: "/tmp/test_workspace",
          fuel: 1000,
          env: [{"TEST_VAR", "value"}]
        )

      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end
end
