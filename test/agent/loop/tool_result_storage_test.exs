defmodule OptimalSystemAgent.Agent.Loop.ToolResultStorageTest do
  @moduledoc """
  Output-shorten-to-file at the tool-output boundary (steal-list #16 /
  reconciliation U-A4: opencode `tool/truncate.ts`).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage
  alias OptimalSystemAgent.Settings

  setup do
    if :ets.whereis(:osa_settings) == :undefined do
      :ets.new(:osa_settings, [:named_table, :public, :set])
    end

    :ets.delete(:osa_settings, {:session, "verbose"})

    on_exit(fn ->
      if :ets.whereis(:osa_settings) != :undefined do
        :ets.delete(:osa_settings, {:session, "verbose"})
      end

      Application.delete_env(:optimal_system_agent, :max_tool_output_lines)
      Application.delete_env(:optimal_system_agent, :tool_output_preview_head_lines)
      Application.delete_env(:optimal_system_agent, :tool_output_preview_tail_lines)
    end)

    :ok
  end

  describe "small output" do
    test "passes through completely unchanged" do
      small = "just a normal, short tool result\n"
      assert ToolResultStorage.apply_budget(small, "shell_execute", "call_small") == small
    end
  end

  describe "byte-threshold offload" do
    test "huge output (over byte cap) is written to a file with a head+tail preview" do
      session = "tr-storage-bytes-#{System.unique_integer([:positive])}"
      # Well over the 51_200-byte config.exs threshold.
      big = Enum.map_join(1..3000, "\n", &"line #{&1} #{String.duplicate("x", 20)}")

      result =
        ToolResultStorage.apply_budget(big, "shell_execute", "call_bytes_#{session}", session)

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      refute result == big
      assert byte_size(result) < byte_size(big)

      assert result =~ "Full output written to"
      assert result =~ "read it with file_read"

      # Extract the persisted path out of the reference note and verify the
      # FULL original content actually landed there.
      [_, path] = Regex.run(~r/Full output written to (\S+) /, result)
      assert File.exists?(path)
      assert File.read!(path) == big

      # Head+tail: first line and last line both present in the preview,
      # with an omission marker in between (not just a head slice).
      assert result =~ "line 1 "
      assert result =~ "line 3000 "
      assert result =~ "lines omitted"
    end
  end

  describe "line-threshold offload" do
    test "output under the byte cap but over the line cap is still offloaded" do
      session = "tr-storage-lines-#{System.unique_integer([:positive])}"
      # 2500 short lines — well under 51_200 bytes but over the 2000-line cap.
      many_short_lines = Enum.map_join(1..2500, "\n", &"l#{&1}")
      assert byte_size(many_short_lines) < 51_200

      result =
        ToolResultStorage.apply_budget(
          many_short_lines,
          "grep_search",
          "call_lines_#{session}",
          session
        )

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      refute result == many_short_lines
      assert result =~ "Full output written to"
      assert result =~ "2500 lines"

      [_, path] = Regex.run(~r/Full output written to (\S+) /, result)
      assert File.read!(path) == many_short_lines
    end
  end

  describe "config-gated thresholds" do
    test "max_tool_output_lines is honored" do
      Application.put_env(:optimal_system_agent, :max_tool_output_lines, 10)
      session = "tr-storage-cfg-lines-#{System.unique_integer([:positive])}"
      content = Enum.map_join(1..20, "\n", &"row#{&1}")

      result =
        ToolResultStorage.apply_budget(content, "shell_execute", "call_cfg_#{session}", session)

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      refute result == content
      assert result =~ "Full output written to"
    end

    test "preview head/tail line counts are honored" do
      Application.put_env(:optimal_system_agent, :tool_output_preview_head_lines, 2)
      Application.put_env(:optimal_system_agent, :tool_output_preview_tail_lines, 2)
      Application.put_env(:optimal_system_agent, :max_tool_output_lines, 10)

      session = "tr-storage-cfg-preview-#{System.unique_integer([:positive])}"
      content = Enum.map_join(1..50, "\n", &"row#{&1}")

      result =
        ToolResultStorage.apply_budget(content, "shell_execute", "call_pv_#{session}", session)

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      assert result =~ "row1\nrow2\n\n"
      assert result =~ "row49\nrow50"
      refute result =~ "row25"
    end
  end

  describe "verbose bypass (existing behavior preserved)" do
    test "verbose=true returns full tool output without truncation" do
      Settings.set_session("verbose", true)
      big = String.duplicate("x", 60_000)
      assert ToolResultStorage.apply_budget(big, "shell_execute", "call_verbose") == big
    end
  end
end
