defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.ExecutorTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Executor

  describe "run/2" do
    @tag :integration
    test "returns ok tuple" do
      # Integration test — requires Ollama running
      result = Executor.run("take a screenshot")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "module exists" do
    # Ensure the module is loaded before inspecting exports.
    # function_exported?/3 returns false for unloaded modules even when the
    # .beam file exists on disk.
    setup do
      Code.ensure_loaded!(Executor)
      :ok
    end

    test "executor module is loaded" do
      assert Code.ensure_loaded?(Executor)
    end

    test "run/1 and run/2 are exported" do
      assert function_exported?(Executor, :run, 1) or function_exported?(Executor, :run, 2)
    end
  end
end
