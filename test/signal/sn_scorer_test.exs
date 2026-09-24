defmodule OptimalSystemAgent.Signal.SnScorerTest do
  @moduledoc """
  Unit tests for `OptimalSystemAgent.Signal.SnScorer` — cheap heuristic
  signal-to-noise scoring for OSA's own final answers (Signal Theory's
  noise-elimination checklist applied to the model's OWN output, not just to
  the user's input).

  No LLM calls anywhere in this module or these tests — every check is a
  regex/heuristic over the finished text.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Signal.SnScorer

  describe "score/2 — clean output" do
    test "a short, direct answer with no filler scores high" do
      assert SnScorer.score("Run `mix test` to verify the fix.") > 0.8
    end

    test "a well-structured multi-sentence answer with real content scores high" do
      text =
        "The bug was a missing nil check in `parse/1`. Add a guard clause before " <>
          "the pattern match and the crash stops."

      assert SnScorer.score(text) > 0.7
    end

    test "empty text scores 0.0" do
      assert SnScorer.score("") == 0.0
      assert SnScorer.score(nil) == 0.0
    end
  end

  describe "score/2 — filler phrases" do
    test "a filler-heavy opener drags the score down" do
      clean = "The build is fixed."
      noisy = "Let me think about this. That's a great question! " <> clean

      assert SnScorer.score(noisy) < SnScorer.score(clean)
    end

    test "reasons/1 reports :filler when a known filler phrase is present" do
      assert :filler in SnScorer.reasons("I hope this helps! Here is the answer.")
    end
  end

  describe "score/2 — hedging" do
    test "hedged language drags the score down relative to a direct equivalent" do
      direct = "The service is down because the config key is missing."

      hedged =
        "Perhaps we could consider that it might possibly be because the config key is missing."

      assert SnScorer.score(hedged) < SnScorer.score(direct)
    end

    test "reasons/1 reports :hedging when hedge patterns are present" do
      assert :hedging in SnScorer.reasons("It might be worth checking the config.")
    end
  end

  describe "score/2 — restated question" do
    test "opening by echoing the user's question back drags the score down" do
      question = "why is the deploy failing"
      restated = "Why is the deploy failing? The deploy is failing because the token expired."
      answer_only = "The token expired."

      assert SnScorer.score(restated, question: question) <
               SnScorer.score(answer_only, question: question)
    end

    test "reasons/2 reports :restated_question when the opener echoes the question" do
      question = "what is the current status"
      restated = "What is the current status? Everything is green."
      assert :restated_question in SnScorer.reasons(restated, question: question)
    end

    test "without a question option, no restated-question penalty applies" do
      refute :restated_question in SnScorer.reasons("Why is the deploy failing? It is not.")
    end
  end

  describe "score/2 — repetition" do
    test "an immediately repeated sentence drags the score down" do
      once = "The cache is stale. Clear it and retry."
      twice = "The cache is stale. The cache is stale. Clear it and retry."

      assert SnScorer.score(twice) < SnScorer.score(once)
    end

    test "reasons/1 reports :repetition for a duplicated sentence" do
      assert :repetition in SnScorer.reasons("Deploy succeeded. Deploy succeeded.")
    end
  end

  describe "trim/1" do
    test "removes a leading filler sentence and keeps the substance" do
      trimmed = SnScorer.trim("Let me think about this. The fix is in `foo.ex` line 12.")
      refute trimmed =~ "Let me think about this"
      assert trimmed =~ "foo.ex"
    end

    test "collapses a duplicated sentence to one occurrence" do
      trimmed = SnScorer.trim("Done. Done. Moving on.")
      assert trimmed == "Done. Moving on."
    end

    test "text with no filler or repetition is returned unchanged (aside from whitespace)" do
      assert SnScorer.trim("The fix is in place.") == "The fix is in place."
    end

    test "never returns an empty string for non-empty input" do
      refute SnScorer.trim("Great question! Thank you for your patience!") == ""
    end
  end

  describe "enforce/2" do
    test "returns the trimmed text plus a metadata map with score and reasons" do
      {text, meta} = SnScorer.enforce("Let me think about this. Done.")
      assert is_binary(text)
      refute text =~ "Let me think about this"
      assert is_float(meta.score)
      assert is_list(meta.reasons)
      assert meta.trimmed? == true
    end

    test "trimmed? is false when nothing needed trimming" do
      {_text, meta} = SnScorer.enforce("Done.")
      assert meta.trimmed? == false
    end

    test "never raises on nil or non-binary input" do
      {text, meta} = SnScorer.enforce(nil)
      assert text == nil
      assert meta.score == 0.0
    end
  end
end
