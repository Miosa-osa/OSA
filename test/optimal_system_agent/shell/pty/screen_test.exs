defmodule OptimalSystemAgent.Shell.Pty.ScreenTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Shell.Pty.Screen

  defp text(bytes) do
    Screen.new(20, 5) |> Screen.feed(bytes) |> Screen.text()
  end

  test "plain text renders" do
    assert text("hello") == "hello"
  end

  test "CR/LF produce separate lines" do
    assert text("line1\r\nline2") == "line1\nline2"
  end

  test "carriage return overwrites in place" do
    # "abcdef" then CR then "XYZ" overwrites the first three cells.
    assert text("abcdef\rXYZ") == "XYZdef"
  end

  test "backspace moves the cursor back" do
    assert text("abc\b\bX") == "aXc"
  end

  test "SGR color codes are stripped from the text" do
    assert text("\e[31mred\e[0m") == "red"
  end

  test "cursor addressing (CSI H) positions writes" do
    # Home, write A; move to row 2 col 1, write B.
    assert text("\e[1;1HA\e[2;1HB") == "A\nB"
  end

  test "erase-display (CSI 2J) clears the grid" do
    assert text("garbage\e[2J") == ""
  end

  test "erase-line to end (CSI K)" do
    # Write, CR home the col, then CSI 0K erases from cursor to end of line.
    assert text("abcdef\r\e[0K") == ""
  end

  test "OSC title sequence is consumed, not rendered" do
    assert text("\e]0;my title\avisible") == "visible"
  end

  test "line feed scrolls and fills scrollback when past the bottom" do
    # 5-row screen; write 7 lines so the first 2 scroll off.
    bytes = Enum.map_join(1..7, "", fn n -> "row#{n}\r\n" end)
    s = Screen.new(20, 5) |> Screen.feed(bytes)
    sb = Screen.scrollback(s, :all)
    assert "row1" in sb
    assert "row2" in sb
    # The visible screen retains the most recent rows.
    assert Screen.text(s) =~ "row7"
  end

  test "cursor position is 1-based" do
    s = Screen.new(20, 5) |> Screen.feed("ab")
    assert Screen.cursor(s) == %{row: 1, col: 3}
  end

  test "split escape across feeds is reassembled" do
    s = Screen.new(20, 5) |> Screen.feed("A\e[") |> Screen.feed("2;1HB")
    assert Screen.text(s) == "A\nB"
  end

  describe "malformed byte safety (the decoder must never crash the session)" do
    # `ensure_utf8/1` used to return its argument unchanged on BOTH branches of
    # `case String.valid?`, and its only caller pattern-matched the result with
    # `<<_ignored::utf8, tail::binary>>`. Any non-UTF-8 lead byte after ESC
    # therefore raised MatchError inside the PTY session process, killing it and
    # its buffered scrollback.
    test "a raw non-UTF-8 byte after ESC is consumed, not a MatchError" do
      s = Screen.new(20, 5) |> Screen.feed(<<"A", 0x1B, 0xFF, "B">>)
      assert Screen.text(s) == "AB"
    end

    test "every possible byte after ESC is survivable" do
      for b <- 0..255, b not in [?[, ?]] do
        s = Screen.new(20, 5) |> Screen.feed(<<"A", 0x1B, b, "B">>)
        assert is_binary(Screen.text(s)), "ESC + byte #{b} crashed the decoder"
      end
    end

    test "a lone continuation byte in the stream does not crash" do
      s = Screen.new(20, 5) |> Screen.feed(<<"A", 0x80, 0xBF, "B">>)
      assert is_binary(Screen.text(s))
    end
  end

  describe "multi-byte characters split across feed boundaries" do
    # `pending` was only ever set to a partial ESCAPE sequence, so a character
    # straddling a chunk boundary fell through to the catch-all clause and was
    # silently discarded byte by byte.
    test "a 3-byte CJK character split across two feeds is preserved" do
      s =
        Screen.new(20, 5)
        |> Screen.feed(<<"A", 0xE4, 0xB8>>)
        |> Screen.feed(<<0xAD, "B">>)

      assert Screen.text(s) == "A中B"
    end

    test "a 4-byte emoji split across three feeds is preserved" do
      <<b1, b2, b3, b4>> = "😀"

      s =
        Screen.new(20, 5)
        |> Screen.feed(<<b1>>)
        |> Screen.feed(<<b2, b3>>)
        |> Screen.feed(<<b4>>)

      assert Screen.text(s) == "😀"
    end

    test "a 2-byte character split across two feeds is preserved" do
      <<b1, b2>> = "é"
      s = Screen.new(20, 5) |> Screen.feed(<<"a", b1>>) |> Screen.feed(<<b2, "b">>)
      assert Screen.text(s) == "aéb"
    end

    test "a truncated sequence that never completes cannot wedge the decoder" do
      # A lead byte followed by ASCII is malformed, not a prefix — it must be
      # dropped, not stashed and re-prepended forever.
      s = Screen.new(20, 5) |> Screen.feed(<<0xE4, "AB">>) |> Screen.feed("C")
      assert Screen.text(s) == "ABC"
    end
  end

  describe "text_utf8/1" do
    test "renders raw binary output as valid UTF-8" do
      s = Screen.new(20, 5) |> Screen.feed(<<"A", 0x80, "B">>)
      out = Screen.text_utf8(s)
      assert String.valid?(out)
      # It must survive the JSON encoder that every provider request body uses.
      assert is_binary(Jason.encode_to_iodata!(%{"screen" => out}) |> IO.iodata_to_binary())
    end
  end
end
