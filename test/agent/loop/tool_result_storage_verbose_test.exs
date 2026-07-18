defmodule OptimalSystemAgent.Agent.Loop.ToolResultStorageVerboseTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage
  alias OptimalSystemAgent.Settings

  setup do
    if :ets.whereis(:osa_settings) == :undefined do
      :ets.new(:osa_settings, [:named_table, :public, :set])
    end

    on_exit(fn ->
      if :ets.whereis(:osa_settings) != :undefined do
        :ets.delete(:osa_settings, {:session, "verbose"})
      end
    end)

    :ok
  end

  test "verbose=true returns full tool output without truncation" do
    Settings.set_session("verbose", true)
    # Above the budget (51_200) so this proves verbose bypasses truncation.
    big = String.duplicate("x", 60_000)
    assert ToolResultStorage.apply_budget(big, "shell_execute", "call_verbose") == big
  end

  test "verbose unset budgets large output" do
    :ets.delete(:osa_settings, {:session, "verbose"})
    # Must exceed the configured max_tool_output_bytes (config.exs: 51_200).
    big = String.duplicate("y", 60_000)
    result = ToolResultStorage.apply_budget(big, "shell_execute", "call_budgeted")
    assert result != big
    assert byte_size(result) < byte_size(big)
  end
end
