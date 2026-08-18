defmodule OptimalSystemAgent.Channels.CLI.LineEditorWidthTest do
  @moduledoc """
  Long input must not wrap at column 80 on a wider terminal (#121).

  `:io.columns/0` answers `{:error, :enotsup}` for this editor - it reads a raw
  `/dev/tty` fd directly, bypassing `prim_tty` - so the width always fell to a
  hardcoded 80. On a 140-column terminal the wrap arithmetic then used the wrong
  column count and the tail of a long line was never displayed.

  The `stty size` shell-out needs a live terminal fd and cannot run under
  `mix test`. The PARSING can, and is the part that actually goes wrong.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.CLI.LineEditor

  describe "stty size parsing" do
    test "reads the column count from '<rows> <cols>'" do
      assert LineEditor.parse_stty_size("24 140", 80) == 140
      assert LineEditor.parse_stty_size("50 200\n", 80) == 200
    end

    test "tolerates the whitespace a tty actually emits" do
      assert LineEditor.parse_stty_size("  24   140  \n", 80) == 140
    end

    test "a wide terminal is not silently narrowed to the fallback" do
      # The bug: any failure to parse quietly returned 80, which is
      # indistinguishable from a real 80-column terminal.
      refute LineEditor.parse_stty_size("24 140", 80) == 80
    end
  end

  describe "bad output falls back instead of guessing" do
    test "empty, partial or non-numeric output uses the fallback" do
      for bad <- ["", "   ", "24", "rows cols", "24 abc", "\n"] do
        assert LineEditor.parse_stty_size(bad, 80) == 80, "#{inspect(bad)} was not rejected"
      end
    end

    test "a zero or negative width is rejected" do
      # A 0-column terminal would make the wrap maths divide by zero.
      assert LineEditor.parse_stty_size("24 0", 80) == 80
      assert LineEditor.parse_stty_size("24 -5", 80) == 80
    end

    test "a non-binary input cannot crash the editor" do
      assert LineEditor.parse_stty_size(nil, 80) == 80
    end
  end
end
