defmodule OptimalSystemAgent.CLI.RendererWidthTest do
  @moduledoc """
  Column correctness through the PUBLIC renderers, not just the width helper.

  These are the assertions that fail against the pre-fix `channels/cli/renderer.ex`
  and `channels/cli/task_display.ex`, which sized their boxes with
  `String.length/1` and could not break an over-long token.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Tasks.Tracker.Task
  alias OptimalSystemAgent.Channels.CLI.{Renderer, TaskDisplay}
  alias OptimalSystemAgent.CLI.Width, as: W

  describe "Renderer.wrap_text/2" do
    test "never emits a line wider than the box, even for an unbreakable token" do
      url = "https://example.com/" <> String.duplicate("path-segment/", 10)

      for line <- Renderer.wrap_text(url, 40) do
        assert W.visible(line) <= 40,
               "an over-long token blew out the box: #{W.visible(line)} of 40 columns"
      end
    end

    test "never emits a line wider than the box for CJK content" do
      text = String.duplicate("日本語のテキスト ", 12)

      for line <- Renderer.wrap_text(text, 30) do
        assert W.visible(line) <= 30,
               "wide glyphs overflowed the box: #{inspect(line)} = #{W.visible(line)} of 30"
      end
    end

    test "ANSI-coloured text is measured by its visible columns only" do
      colored = Enum.map_join(1..20, " ", &"\e[31mword#{&1}\e[0m")

      for line <- Renderer.wrap_text(colored, 40) do
        assert W.visible(line) <= 40
      end
    end
  end

  describe "TaskDisplay.render/2 keeps its box square" do
    defp task(title),
      do: %Task{id: "t1", title: title, status: :in_progress, tokens_used: 0}

    defp row_widths(out) do
      out
      |> String.split("\n")
      |> Enum.map(&W.visible/1)
    end

    test "every row is the same width for an ascii title" do
      widths = row_widths(TaskDisplay.render([task("write the parser")]))
      assert length(Enum.uniq(widths)) == 1, "rows disagree: #{inspect(widths)}"
    end

    test "every row is the same width for an EMOJI title (model-authored)" do
      # Task titles are model-authored and routinely contain emoji. Sized by
      # String.length/1 each emoji stole one column and tore the `│` border.
      widths = row_widths(TaskDisplay.render([task("🎉 ship the release 🚀")]))

      assert length(Enum.uniq(widths)) == 1,
             "the emoji title tore the box border: row widths #{inspect(widths)}"
    end

    test "every row is the same width for a CJK title" do
      widths = row_widths(TaskDisplay.render([task("パーサーを実装する")]))

      assert length(Enum.uniq(widths)) == 1,
             "the CJK title tore the box border: row widths #{inspect(widths)}"
    end

    test "a mixed roster of ascii, emoji and CJK titles all agree" do
      out =
        TaskDisplay.render([
          task("plain ascii title"),
          task("🎉 emoji title"),
          task("日本語のタイトル"),
          task("混ざった🚀mixed")
        ])

      widths = row_widths(out)

      assert length(Enum.uniq(widths)) == 1,
             "rows sheared against each other: #{inspect(widths)}"
    end

    test "an over-long title is fitted, never overflowing the box" do
      out = TaskDisplay.render([task(String.duplicate("あ", 200))])
      widths = row_widths(out)
      assert length(Enum.uniq(widths)) == 1, "widths #{inspect(widths)}"
    end
  end
end
