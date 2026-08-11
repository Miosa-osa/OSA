defmodule OptimalSystemAgent.CLI.WidthTest do
  @moduledoc """
  Display-width correctness for the CLI renderers.

  Every assertion here fails against the pre-fix code, which sized boxes with
  `String.length/1` (graphemes, not columns), stripped only SGR out of ANSI, and
  could not break a token wider than the box.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.CLI.Width, as: W

  describe "visible/1 measures COLUMNS, not graphemes" do
    test "a CJK grapheme is two columns" do
      # String.length("日本語") == 3. It occupies 6 columns.
      assert W.visible("日本語") == 6
      assert String.length("日本語") == 3
    end

    test "an emoji is two columns" do
      assert W.visible("🎉") == 2
    end

    test "a combining mark adds no column of its own" do
      assert W.visible("é") == 1
    end

    test "an emoji ZWJ sequence is ONE glyph, not the sum of its parts" do
      # Summing per-codepoint widths would give 6-8 here.
      assert W.visible("👨‍👩‍👧") == 2
    end

    test "ascii is unchanged" do
      assert W.visible("hello world") == 11
    end
  end

  describe "strip_ansi/1 removes the FULL escape set, not just SGR" do
    test "SGR" do
      assert W.visible("\e[31mred\e[0m") == 3
    end

    test "cursor-movement CSI occupies no columns" do
      # The old SGR-only regex left this in the string and counted all 4 chars.
      assert W.visible("\e[2Kab") == 2
      assert W.visible("\e[10;20Hx") == 1
    end

    test "an OSC-8 hyperlink shows only its label" do
      link = "\e]8;;https://example.com/a/very/long/target\aclick\e]8;;\a"
      assert W.visible(link) == 5
      assert W.strip_ansi(link) == "click"
    end
  end

  describe "fit/2 never overflows its span and never splits a cluster" do
    test "a wide value is cut to its column budget" do
      out = W.fit("日本語のタイトルです", 8)
      assert W.visible(out) <= 8
    end

    test "the budget holds for every width and every sample" do
      for s <- ["日本語のセッションタイトル", "🎉🎉🎉🎉", "👨‍👩‍👧 family", "plain ascii", "混ざったmixed"],
          w <- 0..20 do
        assert W.visible(W.fit(s, w)) <= w,
               "fit(#{inspect(s)}, #{w}) = #{inspect(W.fit(s, w))} overflows"
      end
    end

    test "a value that fits is returned untouched" do
      assert W.fit("short", 40) == "short"
    end

    test "an emoji ZWJ family is never cut in half" do
      # Budget 2 leaves 1 column after the ellipsis, which cannot hold the
      # 2-column family — so it is dropped whole rather than dismembered.
      refute String.contains?(W.fit("👨‍👩‍👧x", 2), "👨‍👩")
    end
  end

  describe "pad/2 makes a row own EXACTLY its columns" do
    test "padding is column-exact for wide content" do
      for s <- ["日本語", "🎉ok", "ascii", "é"], w <- 0..16 do
        assert W.visible(W.pad(s, w)) == w,
               "pad(#{inspect(s)}, #{w}) does not own exactly #{w} columns"

        assert W.visible(W.pad_start(s, w)) == w
      end
    end
  end

  describe "wrap/2 can break an over-long token" do
    test "a URL wider than the box is broken, not emitted intact" do
      url = "https://example.com/" <> String.duplicate("segment/", 12)
      lines = W.wrap(url, 40)

      assert length(lines) > 1

      for l <- lines do
        assert W.visible(l) <= 40,
               "an over-long token blew out the box: #{inspect(l)} is #{W.visible(l)} columns"
      end
    end

    test "a base64 blob is broken" do
      blob = String.duplicate("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=", 4)

      for l <- W.wrap(blob, 32) do
        assert W.visible(l) <= 32
      end
    end

    test "no wrapped line ever exceeds the width, for wide content too" do
      text = "日本語のとても長い説明文がここに入ります " <> String.duplicate("あ", 60)

      for l <- W.wrap(text, 30) do
        assert W.visible(l) <= 30, "#{inspect(l)} is #{W.visible(l)} columns"
      end
    end

    test "ordinary prose still wraps on word boundaries" do
      lines = W.wrap("the quick brown fox jumps over the lazy dog", 12)
      assert Enum.all?(lines, &(W.visible(&1) <= 12))
      assert Enum.join(lines, " ") == "the quick brown fox jumps over the lazy dog"
    end

    test "leading indentation is preserved, not normalized away" do
      # The old wrap split on ~r/\s+/ and dropped the user's alignment entirely.
      [first | _] = W.wrap("    indented content that is long enough to wrap over", 20)
      assert String.starts_with?(first, "    ")
    end

    test "a short line is passed through byte-identically" do
      assert W.wrap("  keep   my  spacing", 80) == ["  keep   my  spacing"]
    end
  end

  describe "the plan-approval box is column-correct (consent gate)" do
    test "a model-authored plan with wide glyphs pads its box exactly" do
      # Reproduces what plan_review.ex does: wrap to the inner width, then pad
      # each line out to it. If either step measures graphemes, the `│` tears.
      inner = 40

      plan =
        "実装計画: 🎉 add the parser then wire it up and https://example.com/#{String.duplicate("x", 60)}"

      for line <- W.wrap(plan, inner) do
        vis = W.visible(line)
        assert vis <= inner, "line overflows the box: #{inspect(line)} = #{vis} cols"
        assert W.visible(line <> String.duplicate(" ", inner - vis)) == inner
      end
    end
  end
end
