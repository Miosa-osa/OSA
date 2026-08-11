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
    test "replaces every occurrence of an EXACT (verbatim) old_string" do
      # `row()` is a verbatim substring occurring twice — the `:simple` strategy
      # wins and replace_all is legitimate. This is the common, valid case.
      assert {:ok, "col() \nkeep()\ncol() \n", 2, :simple} =
               F.replace("row() \nkeep()\nrow() \n", "row()", "col()", true)
    end
  end

  # ── replace_all is refused for APPROXIMATE strategies ─────────────────
  #
  # An approximate strategy's candidate is a *suggestion about one site*. It is
  # not old_string, so replacing it globally rewrites regions that never
  # contained old_string — silent, on-disk source corruption.

  describe "replace_all under an approximate strategy" do
    # `old` differs from disk only by whitespace RUNS, so nothing before
    # :whitespace_normalized can match it. That strategy then produces the
    # candidate "total = count + 1", which occurs twice: once as the real
    # statement (line 2) and once embedded in a COMMENT (line 1). The comment
    # never contained old_string in any sense — it must not be rewritten.
    @content """
    # note: total = count + 1 is the invariant
    total = count + 1
    """
    @old "total  =  count + 1"
    @new "total = tally()"
    @comment "# note: total = count + 1 is the invariant"

    test "the region that never contained old_string is left untouched" do
      # Property under test, stated independently of how we refuse: after a
      # replace_all request, the comment line is never rewritten.
      surviving =
        case F.replace(@content, @old, @new, true) do
          # Refused — nothing is written, so the comment survives by construction.
          {:error, _} -> @content
          {:error, _, _} -> @content
          {:ok, updated, _count, _strategy} -> updated
        end

      assert String.contains?(surviving, @comment),
             "replace_all under an approximate match rewrote a region that never " <>
               "contained old_string:\n#{surviving}"
    end

    test "refuses with the winning strategy named" do
      assert {:error, {:replace_all_approximate, :whitespace_normalized}} =
               F.replace(@content, @old, @new, true)
    end

    test "the same edit without replace_all is unaffected by the guard" do
      # Both regions still match, so this is ambiguous — as it was before.
      assert {:error, :ambiguous, 2} = F.replace(@content, @old, @new, false)
    end

    test "Matcher surfaces the refusal from the cascade" do
      assert {:error, {:replace_all_approximate, :whitespace_normalized}} =
               Matcher.replace(@content, @old, @new, true)
    end

    test "block_anchor cannot license a replace_all either" do
      content = """
      function calculate(a, b) {
        const result = a + b;
        return result;
      }
      """

      old = "function calculate(a, b) {\n  const result = a+b;\n  return result;\n}\n"

      assert {:error, {:replace_all_approximate, :block_anchor}} =
               F.replace(content, old, "x", true)
    end
  end

  describe "exact_strategy?/1" do
    test "only :simple and :multi_occurrence are exact" do
      assert F.exact_strategy?(:simple)
      assert F.exact_strategy?(:multi_occurrence)

      for s <- F.strategies() -- [:simple, :multi_occurrence] do
        refute F.exact_strategy?(s), "#{s} must be classified approximate"
      end
    end

    test "every strategy atom is classified" do
      for s <- F.strategies(), do: assert(is_boolean(F.exact_strategy?(s)))
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
