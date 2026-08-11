defmodule OptimalSystemAgent.Tools.Builtins.ShellExecuteTruncationTest do
  @moduledoc """
  Output truncation for `shell_execute`.

  The behavior under test: when a command overflows the byte cap, the model must
  still receive the END of the output. For a build or a test run the compiler
  errors, the failure summary and the exit diagnostics all live in the tail —
  head-only truncation threw away exactly the bytes the turn depended on and
  handed the model a screenful of progress output instead.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants

  @head_marker "OSA_HEAD_MARKER"
  @tail_marker "OSA_TAIL_MARKER"

  # Emits marker, ~150KB of filler, marker. Comfortably over the 100KB cap.
  defp overflowing_command do
    "printf '#{@head_marker}\\n'; " <>
      "awk 'BEGIN{ for(i=0;i<4000;i++) print \"filler-line-\" i \"-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\" }'; " <>
      "printf '#{@tail_marker}\\n'"
  end

  defp run(cmd) do
    case ShellExecute.execute(%{"command" => cmd}) do
      {:ok, out} -> out
      {:error, out} -> out
      other -> flunk("unexpected shell_execute result: #{inspect(other)}")
    end
  end

  describe "output under the cap" do
    test "is returned verbatim with no elision marker" do
      out = run("printf 'small output\\n'")
      assert out =~ "small output"
      refute out =~ "truncated"
    end
  end

  describe "output over the cap" do
    setup do
      %{out: run(overflowing_command())}
    end

    # THE regression. On the original head-keep implementation
    # (`binary_part(output, 0, max) <> "[output truncated at 100KB]"`) the tail
    # marker was discarded, so this assertion failed.
    test "keeps the TAIL, where build and test failures actually are", %{out: out} do
      assert out =~ @tail_marker,
             "the end of the output was discarded — the diagnostic the turn needed is gone"
    end

    test "keeps the HEAD as well", %{out: out} do
      assert out =~ @head_marker
    end

    test "states how much was omitted, and from where", %{out: out} do
      assert out =~ ~r/\[\.\.\. output truncated: \d+ lines \/ \d+ bytes omitted from the middle/
    end

    test "the omitted counts are non-zero and plausible", %{out: out} do
      [_, lines, bytes] =
        Regex.run(~r/output truncated: (\d+) lines \/ (\d+) bytes omitted/, out)

      assert String.to_integer(lines) > 0
      assert String.to_integer(bytes) > 0
    end

    test "the head marker precedes the elision, which precedes the tail marker", %{out: out} do
      head_at = :binary.match(out, @head_marker) |> elem(0)
      elision_at = :binary.match(out, "output truncated") |> elem(0)
      tail_at = :binary.match(out, @tail_marker) |> elem(0)

      assert head_at < elision_at
      assert elision_at < tail_at
    end

    test "still honours the byte cap (plus the elision marker itself)", %{out: out} do
      # The cap is a BYTE budget, not a character budget.
      assert byte_size(out) <= Constants.max_output_bytes() + 200
    end

    test "is valid UTF-8 even though both cuts can land mid-codepoint", %{out: out} do
      assert String.valid?(out)
    end
  end

  describe "multibyte output over the cap" do
    test "survives cuts on both the head and the tail boundary" do
      # Every line is 3-byte UTF-8, so both binary_part cuts are very likely to
      # land inside a codepoint.
      cmd =
        "printf '#{@head_marker}\\n'; " <>
          "awk 'BEGIN{ for(i=0;i<12000;i++) print \"日本語のテキストです日本語のテキストです\" }'; " <>
          "printf '#{@tail_marker}\\n'"

      out = run(cmd)

      assert String.valid?(out)
      assert out =~ @head_marker
      assert out =~ @tail_marker
    end
  end
end
