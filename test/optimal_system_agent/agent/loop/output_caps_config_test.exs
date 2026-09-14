defmodule OptimalSystemAgent.Agent.Loop.OutputCapsConfigTest do
  @moduledoc """
  Gap #1 — three formerly-hardcoded output caps are now runtime-configurable via
  Application env (defaults unchanged), plus the background-completion answer is
  no longer clipped to 500 chars (item: full/ResultSummarizer-parity answer).

  These caps all bound "how much tool/command output flows into context", the
  same runaway lever as item 9; keeping them in one owner keeps their defaults
  coherent (summary cap < loop cap, verified in the compactor's own comment).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants, as: ShellConstants
  alias OptimalSystemAgent.Shell.TerminalOutputSaver
  alias OptimalSystemAgent.Orchestrator

  defp with_env(key, value, fun) do
    prev = Application.get_env(:optimal_system_agent, key)

    try do
      Application.put_env(:optimal_system_agent, key, value)
      fun.()
    after
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, key)
        v -> Application.put_env(:optimal_system_agent, key, v)
      end
    end
  end

  describe "shell_execute bash_output_max_bytes" do
    test "defaults to the original 100 KB" do
      with_env(:bash_output_max_bytes, nil, fn ->
        assert ShellConstants.max_output_bytes() == 102_400
      end)
    end

    test "honors the configured override" do
      with_env(:bash_output_max_bytes, 4_096, fn ->
        assert ShellConstants.max_output_bytes() == 4_096
      end)
    end

    test "ignores a non-positive override" do
      with_env(:bash_output_max_bytes, 0, fn ->
        assert ShellConstants.max_output_bytes() == 102_400
      end)
    end
  end

  describe "terminal_output_saver terminal_output_max_chars" do
    test "defaults to the original 8 KB" do
      with_env(:terminal_output_max_chars, nil, fn ->
        assert TerminalOutputSaver.max_output_chars() == 8_000
      end)
    end

    test "the save threshold follows the configured cap" do
      with_env(:terminal_output_max_chars, 100, fn ->
        assert TerminalOutputSaver.max_output_chars() == 100
        refute TerminalOutputSaver.should_save?(String.duplicate("x", 100))
        assert TerminalOutputSaver.should_save?(String.duplicate("x", 101))
      end)
    end
  end

  describe "background completion answer is not clipped to 500 chars" do
    test "carries the full answer up to the ResultSummarizer-parity bound" do
      tail = "FINDING: the real conclusion lives past character 500 — do not lose me."
      report = String.duplicate("filler ", 100) <> tail
      assert String.length(report) > 500

      out = Orchestrator.background_result_text(report)

      assert out == report
      assert out =~ tail
    end

    test "still bounds a pathological oversized answer without splitting UTF-8" do
      huge = String.duplicate("😀", 20_000)
      out = Orchestrator.background_result_text(huge)

      assert String.length(out) == 10_000
      assert String.valid?(out)
    end
  end
end
