defmodule OptimalSystemAgent.Channels.CLI.LineEditorWrapTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.CLI.LineEditor

  test "long logical lines are counted as terminal visual rows" do
    text = String.duplicate("x", 170)

    assert LineEditor.visual_layout(text, 4, 80, 170) == %{
             rendered_rows: 3,
             cursor_row: 2,
             cursor_col: 14
           }
  end

  test "explicit newlines and terminal wrapping compose" do
    text = String.duplicate("a", 77) <> "\n" <> String.duplicate("界", 41)

    assert LineEditor.visual_layout(text, 2, 80, String.length(text)) == %{
             rendered_rows: 3,
             cursor_row: 2,
             cursor_col: 4
           }
  end
end
