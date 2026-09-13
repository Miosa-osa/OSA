defmodule OptimalSystemAgent.Channels.CLI.LineEditorMouseTest do
  @moduledoc """
  Click-to-position for the CLI input box (#121).

  Without it, the only cursor movers are Left/Right/Home/End, so reaching an
  edit site mid-line means holding an arrow key — which is why the report says
  backspace "only deletes the last character" in practice.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.CLI.LineEditor

  describe "SGR mouse reports" do
    test "a left-press is parsed with 0-based coordinates" do
      # Wire form is 1-based; index_at/5 works in 0-based rows and columns.
      assert {:mouse, 0, 9, 0, true} = LineEditor.parse_sgr_mouse("0;10;1M")
    end

    test "release is distinguished from press" do
      assert {:mouse, 0, 4, 2, false} = LineEditor.parse_sgr_mouse("0;5;3m")
    end

    test "a drag carries its own button code" do
      assert {:mouse, 32, 19, 1, true} = LineEditor.parse_sgr_mouse("32;20;2M")
    end
  end

  describe "a malformed report is discarded, not guessed at" do
    test "junk never moves the cursor" do
      # Anything unrecognised must be dropped: acting on a half-parsed report
      # would jump the cursor somewhere arbitrary mid-edit.
      for bad <- ["", "0;10", "0;10;1", "0;10;1X", "a;b;cM", "0;0;1M", "0;10;0M", ";;M"] do
        assert LineEditor.parse_sgr_mouse(bad) == :unknown, "#{inspect(bad)} was accepted"
      end
    end

    test "a non-binary payload cannot crash the editor" do
      assert LineEditor.parse_sgr_mouse(nil) == :unknown
    end
  end

  describe "click maps to a grapheme index" do
    @prompt 2
    @cols 80

    test "a click lands on the character under it" do
      text = "hello world"
      # Row 0, column 2 is the first character after a 2-wide prompt.
      assert LineEditor.index_at(text, @prompt, @cols, 0, 2) == 0
      assert LineEditor.index_at(text, @prompt, @cols, 0, 8) == 6
    end

    test "a click past the end of the text clamps to the end" do
      text = "abc"
      assert LineEditor.index_at(text, @prompt, @cols, 0, 70) == 3
    end

    test "the prompt is not counted twice on the first row" do
      # The exact bug called out in the report. Clicking the very first
      # character must give index 0, not an index shifted by the prompt width.
      assert LineEditor.index_at("abcdef", 8, @cols, 0, 8) == 0
    end

    test "a click on a wrapped row resolves to that row, not the one above" do
      # 200 chars over an 80-column terminal wraps to three rows. Row must
      # dominate the distance metric or every click collapses onto row 0.
      text = String.duplicate("x", 200)
      index = LineEditor.index_at(text, @prompt, @cols, 1, 0)

      layout = LineEditor.visual_layout(text, @prompt, @cols, index)
      assert layout.cursor_row == 1, "click on row 1 resolved to row #{layout.cursor_row}"
    end

    test "the mapping is the exact inverse of the renderer" do
      # The property that makes this safe: whatever index we return, laying it
      # out again must reproduce the clicked position.
      text = "the quick brown fox jumps over the lazy dog"

      for index <- [0, 5, 17, 42] do
        layout = LineEditor.visual_layout(text, @prompt, @cols, index)

        round_trip =
          LineEditor.index_at(text, @prompt, @cols, layout.cursor_row, layout.cursor_col)

        assert round_trip == index, "index #{index} did not round-trip (got #{round_trip})"
      end
    end
  end
end
