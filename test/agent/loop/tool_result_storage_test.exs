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

  describe "key lines — errors and matches surfaced alongside head+tail" do
    test "a line matching an error pattern outside the head/tail window is surfaced" do
      session = "tr-storage-keylines-#{System.unique_integer([:positive])}"

      lines =
        List.duplicate("ok", 100) ++
          ["Error: connection refused on line 101"] ++ List.duplicate("ok", 3000)

      big = Enum.join(lines, "\n")

      result =
        ToolResultStorage.apply_budget(big, "shell_execute", "call_kl_#{session}", session)

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      assert result =~ "Key lines"
      assert result =~ "Error: connection refused on line 101"
    end

    test "content with no error-like lines gets no Key lines section" do
      session = "tr-storage-nokeylines-#{System.unique_integer([:positive])}"
      big = Enum.map_join(1..3000, "\n", &"row #{&1} is perfectly fine")

      result =
        ToolResultStorage.apply_budget(big, "shell_execute", "call_nkl_#{session}", session)

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      refute result =~ "Key lines"
    end
  end

  describe "reference note carries a handle" do
    test "the note names a short handle in addition to the full path" do
      session = "tr-storage-handle-#{System.unique_integer([:positive])}"
      big = Enum.map_join(1..3000, "\n", &"line #{&1}")

      result =
        ToolResultStorage.apply_budget(big, "shell_execute", "call_handle_#{session}", session)

      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      [_, path] = Regex.run(~r/Full output written to (\S+) /, result)
      handle = Path.basename(path)

      assert result =~ "Handle: #{handle}"
    end
  end

  describe "persist/4 — the shared write path" do
    test "writes content to the tool-results directory and returns its path" do
      session = "tr-storage-persist-#{System.unique_integer([:positive])}"
      content = "hello from persist/4"

      assert {:ok, path} = ToolResultStorage.persist(content, "shell_execute", "call_p1", session)
      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      assert File.read!(path) == content
      assert Path.basename(path) == "#{session}_call_p1_shell_execute.txt"
    end

    test "apply_budget's own offload goes through persist/4's exact filename scheme" do
      session = "tr-storage-persist2-#{System.unique_integer([:positive])}"
      big = Enum.map_join(1..3000, "\n", &"line #{&1}")

      _ = ToolResultStorage.apply_budget(big, "shell_execute", "call_p2", session)
      on_exit(fn -> ToolResultStorage.cleanup(session) end)

      {:ok, path} = ToolResultStorage.persist("anything", "shell_execute", "call_p2", session)
      assert Path.basename(path) == "#{session}_call_p2_shell_execute.txt"
    end
  end

  describe "expand/2 — retrieval by handle, with a range or a grep" do
    setup do
      session = "tr-storage-expand-#{System.unique_integer([:positive])}"
      content = Enum.map_join(1..500, "\n", &"line #{&1}")
      {:ok, path} = ToolResultStorage.persist(content, "shell_execute", "call_e1", session)
      on_exit(fn -> ToolResultStorage.cleanup(session) end)
      {:ok, path: path, handle: Path.basename(path), content: content}
    end

    test "resolves a bare handle against the shared tool-results directory", %{handle: handle} do
      assert {:ok, out} = ToolResultStorage.expand(handle, limit: 5)
      assert out =~ "line 1"
    end

    test "accepts the full absolute path too", %{path: path} do
      assert {:ok, out} = ToolResultStorage.expand(path, limit: 5)
      assert out =~ "line 1"
    end

    test "range mode honours offset and limit", %{handle: handle} do
      assert {:ok, out} = ToolResultStorage.expand(handle, offset: 100, limit: 3)
      assert out =~ "line 100"
      assert out =~ "line 102"
      refute out =~ "line 103"
      refute out =~ "line 99\n"
    end

    test "grep mode returns only matching lines, with their line numbers", %{handle: handle} do
      assert {:ok, out} = ToolResultStorage.expand(handle, grep: "line 42$")
      assert out =~ "42: line 42"
      refute out =~ "line 420"
    end

    test "grep mode reports no matches without erroring", %{handle: handle} do
      assert {:ok, out} = ToolResultStorage.expand(handle, grep: "nothing-will-match-this")
      assert out =~ "No lines matched"
    end

    test "refuses a handle that escapes the tool-results directory" do
      assert {:error, reason} = ToolResultStorage.expand("../../etc/passwd")
      assert reason =~ "Refusing"
    end

    test "a handle with no stored output returns an error, not a crash" do
      assert {:error, _reason} =
               ToolResultStorage.expand(
                 "does-not-exist-#{System.unique_integer([:positive])}.txt"
               )
    end
  end
end
