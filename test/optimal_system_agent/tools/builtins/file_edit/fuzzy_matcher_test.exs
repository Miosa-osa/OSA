defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.FuzzyMatcherTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.FuzzyMatcher, as: F
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Matcher

  # ── Per-strategy coverage ─────────────────────────────────────────────
  #
  # Strategies that can genuinely win the cascade are exercised through
  # replace/4 (asserting the winning stage atom). Three strategies
  # (indentation_flexible, trimmed_boundary) are *deliberately* shadowed in the
  # cascade by the more-lenient line_trimmed strategy — line_trimmed strips ALL
  # per-line indentation, so any block those two could match, it matches first.
  # They are defensive layers ported faithfully from opencode, so we test their
  # candidate functions directly.

  describe "each strategy matches its case" do
    test "simple: verbatim substring" do
      assert {:ok, "let x = 2\n", 1, :simple} =
               F.replace("let x = 1\n", "x = 1", "x = 2", false)
    end

    test "line_trimmed: trailing/leading whitespace drift on each line" do
      content = "def run do   \n  work()\t\nend\n"
      old = "def run do\n  work()\nend"
      new = "def run do\n  done()\nend"

      assert {:ok, result, 1, :line_trimmed} = F.replace(content, old, new, false)
      assert result =~ "done()"
      refute result =~ "work()"
    end

    test "block_anchor: interior line drift matches via Levenshtein-scored anchors" do
      content = "function calculate(a, b) {\n  const result = a + b;\n  return result;\n}\n"
      # First/last lines are solid anchors; the middle drifted (`a+b` vs `a + b`)
      # but stays well above the 0.65 similarity threshold.
      old = "function calculate(a, b) {\n  const result = a+b;\n  return result;\n}\n"
      new = "function calculate(a, b) {\n  const result = a * b;\n  return result;\n}"

      assert {:ok, result, 1, :block_anchor} = F.replace(content, old, new, false)
      assert result =~ "a * b"
    end

    test "whitespace_normalized: internal whitespace collapsed" do
      assert {:ok, result, 1, :whitespace_normalized} =
               F.replace("const  x   =    42;\n", "const x = 42;", "const x = 99;", false)

      assert result =~ "99"
    end

    test "escape_normalized: literal backslash escape vs a real control char" do
      content = "print(\"hi\tthere\")\n"
      # The model sent a literal backslash-t instead of a real tab.
      old = "print(\"hi\\tthere\")"
      new = "print(\"bye\")"

      assert {:ok, result, 1, :escape_normalized} = F.replace(content, old, new, false)
      assert result =~ "bye"
    end

    test "context_aware: anchors + >=50% interior line agreement (block_anchor rejects it)" do
      # block_anchor is tried first but its Levenshtein average falls below 0.65
      # (one interior line is wholly different); context_aware accepts because the
      # other interior line matches exactly (1/2 = 50%).
      content = "FUNC\n  same_line()\n  ORIGINAL_LONG\nENDF\n"
      old = "FUNC\n  same_line()\n  totally_diff\nENDF\n"
      new = "FUNC\n  replaced()\nENDF"

      assert {:ok, result, 1, :context_aware} = F.replace(content, old, new, false)
      assert result =~ "replaced()"
    end

    test "indentation_flexible: strips common indent, preserves relative indent (direct)" do
      content = "        deeply()\n        indented()\n"
      old = "deeply()\nindented()"

      assert F.indentation_flexible(content, old) == ["        deeply()\n        indented()"]
    end

    test "trimmed_boundary: matches after trimming block boundary (direct)" do
      content = "keep()\ntarget()\nkeep()\n"
      # Leading/trailing newlines + spaces around the core; boundary-trim recovers it.
      assert F.trimmed_boundary(content, "\n  target()\n") == ["target()"]
    end

    test "context_aware candidate function yields the interior-preserving block (direct)" do
      content = "FUNC\n  same_line()\n  ORIGINAL_LONG\nENDF\n"
      old = "FUNC\n  same_line()\n  totally_diff\nENDF\n"

      assert F.context_aware(content, old) == ["FUNC\n  same_line()\n  ORIGINAL_LONG\nENDF"]
    end

    test "multi_occurrence: yields every verbatim occurrence" do
      assert F.multi_occurrence("a\na\nb\na\n", "a") == ["a", "a", "a"]
    end
  end

  # ── replace_all across a fuzzy match ──────────────────────────────────

  describe "replace_all" do
    test "replaces every occurrence of a fuzzy-matched region" do
      # Two identical whitespace-drifted lines; replace_all replaces both.
      assert {:ok, "col() \nkeep()\ncol() \n", 2, _stage} =
               F.replace("row() \nkeep()\nrow() \n", "row()", "col()", true)
    end
  end

  # ── Disproportionate-match guard ───────────────────────────────────────

  describe "disproportionate-match guard" do
    test "disproportionate?/2 flags a span with far more lines than old_string" do
      old = "start\nend"
      big = "start\n" <> String.duplicate("x\n", 20) <> "end"
      assert F.disproportionate?(big, old)
    end

    test "single-line old is never disproportionate on trimmed length" do
      refute F.disproportionate?(String.duplicate("x", 400), "y")
    end

    test "small multi-line old vs a same-line-count match is allowed" do
      refute F.disproportionate?("a\nb", "x\ny")
    end

    test "cascade refuses a fuzzy match whose span dwarfs old_string" do
      # A 2-line old whose whitespace-normalized form matches a region whose raw
      # text is ~600 chars — far larger than old. Refuse rather than clobber.
      content =
        "a" <> String.duplicate(" ", 300) <> "b\n" <> "c" <> String.duplicate(" ", 300) <> "d\n"

      assert {:error, :disproportionate} = F.replace(content, "a b\nc d", "z", false)
    end
  end

  # ── Ambiguity: never silently pick among multiple matches ─────────────

  describe "ambiguity" do
    test "identical fuzzy-matched regions are rejected without replace_all" do
      # Both rows carry the SAME trailing whitespace, so every candidate the
      # cascade produces occurs twice — no unique match exists.
      assert {:error, :ambiguous, 2} =
               F.replace("row() \nkeep()\nrow() \n", "row()", "col()", false)
    end

    test "no candidate at all returns :not_found" do
      assert {:error, :not_found} = F.replace("nothing here\n", "absent()", "x", false)
    end
  end

  # ── Cascade ordering / integration through Matcher ────────────────────

  describe "Matcher integration" do
    test "exact still wins first — never a fuzzy stage" do
      # Line 1 is an exact unique match; line 2 is a fuzzy near-match that must
      # be ignored because exact matching short-circuits the whole cascade.
      content = "value = compute()\nvalue = kompute()  \n"

      assert {:ok, result, 1, :exact} =
               Matcher.replace(content, "value = compute()", "value = cached()", false)

      assert result =~ "cached()"
    end

    test "falls through the local stages into the FuzzyMatcher cascade" do
      # No exact / line-ending / OSA-whitespace match; only block_anchor lands.
      content = "function calculate(a, b) {\n  const result = a + b;\n  return result;\n}\n"
      old = "function calculate(a, b) {\n  const result = a+b;\n  return result;\n}\n"
      new = "function calculate(a, b) {\n  const result = a * b;\n  return result;\n}"

      assert {:ok, result, 1, :block_anchor} = Matcher.replace(content, old, new, false)
      assert result =~ "a * b"
    end

    test "surfaces the disproportionate refusal from the cascade" do
      content =
        "a" <> String.duplicate(" ", 300) <> "b\n" <> "c" <> String.duplicate(" ", 300) <> "d\n"

      assert {:error, :disproportionate} = Matcher.replace(content, "a b\nc d", "z", false)
    end
  end

  # ── Levenshtein sanity ────────────────────────────────────────────────

  describe "levenshtein/2" do
    test "known distances" do
      assert F.levenshtein("kitten", "sitting") == 3
      assert F.levenshtein("", "abc") == 3
      assert F.levenshtein("abc", "abc") == 0
      assert F.levenshtein("flaw", "lawn") == 2
    end
  end
end
