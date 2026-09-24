defmodule OptimalSystemAgent.Signal.SnScorerSafetyTest do
  @moduledoc """
  The explicit safety proof for `SnScorer.trim/1`: it must NEVER remove or
  collapse a sentence containing code, a path, a number, or a command — even
  when that sentence also happens to be a duplicate, or superficially reads
  like filler. Written as its own file (not folded into `sn_scorer_test.exs`)
  because this is the guarantee `:signal_quality_enforcement_enabled` is
  shipped default-ON on the strength of.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Signal.SnScorer

  describe "protected_sentence?/1" do
    test "flags code (backtick), paths, numbers and command words" do
      assert SnScorer.protected_sentence?("Run `mix test` now.")
      assert SnScorer.protected_sentence?("Check /var/log/app.log for the error.")
      assert SnScorer.protected_sentence?("Step 3 restarts the service.")
      assert SnScorer.protected_sentence?("git status shows the diff.")
      assert SnScorer.protected_sentence?("Please curl the endpoint.")
    end

    test "does not flag ordinary prose with none of those signals" do
      refute SnScorer.protected_sentence?("The build is fixed.")
      refute SnScorer.protected_sentence?("Let me think about this.")
    end
  end

  describe "trim/1 never removes a sentence containing code" do
    test "a duplicated command sentence is kept in full, twice" do
      text = "Let me think about this. Run `mix test` to verify. Run `mix test` to verify."
      trimmed = SnScorer.trim(text)

      refute trimmed =~ "Let me think about this"
      assert (trimmed |> String.split("Run `mix test` to verify.") |> length()) - 1 == 2
    end

    test "a single command sentence next to filler survives" do
      text = "I'd be happy to help. Run `git status` before committing."
      trimmed = SnScorer.trim(text)

      refute trimmed =~ "happy to help"
      assert trimmed =~ "Run `git status` before committing."
    end
  end

  describe "trim/1 never removes a sentence containing a path" do
    test "a duplicated path sentence is kept in full, twice" do
      text =
        "Let me think about this. Check /var/log/app.log for the error. " <>
          "Check /var/log/app.log for the error."

      trimmed = SnScorer.trim(text)

      refute trimmed =~ "Let me think about this"
      assert (trimmed |> String.split("/var/log/app.log") |> length()) - 1 == 2
    end
  end

  describe "trim/1 never removes a sentence containing a number" do
    test "a duplicated numbered-step sentence is kept in full, twice" do
      text =
        "That's a great question! Step 3 is to restart the service. " <>
          "Step 3 is to restart the service."

      trimmed = SnScorer.trim(text)

      refute trimmed =~ "great question"
      assert (trimmed |> String.split("Step 3 is to restart the service.") |> length()) - 1 == 2
    end
  end

  describe "trim/1 never removes a sentence containing a shell/VCS command word" do
    test "a duplicated 'git' sentence is kept in full, twice" do
      text =
        "Thank you for your patience. Git tracks every change here. Git tracks every change here."

      trimmed = SnScorer.trim(text)

      refute trimmed =~ "your patience"
      assert (trimmed |> String.split("Git tracks every change here.") |> length()) - 1 == 2
    end
  end

  describe "high-S/N output passes through unchanged" do
    test "trim/1 is a no-op on clean, code/path/number-bearing text" do
      text = "The fix is in `lib/foo.ex` line 42. Run `mix test` to confirm."
      assert SnScorer.trim(text) == text
    end

    test "enforce/2 reports trimmed? false and returns the identical text" do
      text = "The fix is in `lib/foo.ex` line 42. Run `mix test` to confirm."
      {enforced_text, meta} = SnScorer.enforce(text)

      assert enforced_text == text
      assert meta.trimmed? == false
      assert meta.score >= 0.8
    end

    test "a short direct answer scores at or near the ceiling and is never trimmed" do
      text = "Deployed to /srv/app and restarted 2 workers."
      {enforced_text, meta} = SnScorer.enforce(text)

      assert enforced_text == text
      assert meta.score == SnScorer.score(text)
    end
  end
end
