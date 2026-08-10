defmodule OptimalSystemAgent.Memory.AutoExtractTest do
  @moduledoc """
  Regression tests for memory auto-extraction.

  Every string in the "junk that reached production" block below was found
  stored as a real user memory in a live `~/.osa/osa.db`, injected into the
  agent's context on every subsequent turn. They are the specification: if
  any of these starts extracting again, the pile refills.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Memory.AutoExtract

  describe "extract/1 rejects junk that reached production" do
    test "an ordinary task request is not a standing preference" do
      assert AutoExtract.extract("I need your help with some coding tasks tbh") == []
    end

    test "a subagent reviewer brief is not a user correction" do
      brief = """
      You are an ADVERSARIAL, INDEPENDENT reviewer (skeptic #2, VERIFIABILITY lens)
      with NO access to how this change was produced. Your job is to try to REFUTE
      the claim that the goal below was fully achieved.
      """

      assert AutoExtract.extract(brief) == []
    end

    test "an injected scratchpad brief is not a user preference" do
      brief =
        "[shared scratchpad] You are part of a coordinated team. " <>
          "A real, shared directory is available at: /Users/rhl/.osa/scratchpad/session-123"

      assert AutoExtract.extract(brief) == []
    end

    test "'I am' inside a rant does not become an identity memory" do
      rant =
        "well rigt now I am getting an alert that I am about to cap the storage " <>
          "on this computer i legit have 1 terrabyte"

      assert AutoExtract.extract(rant) == []
    end

    test "'fix that' does not become a correction memory" do
      assert AutoExtract.extract("are u sure it i dcan u fix tht ?") == []
    end

    test "a vague question is not a preference" do
      question =
        "Well I want for you to check out my file tree. " <>
          "Tell me what you think about this. Tell me if it's organized right"

      assert AutoExtract.extract(question) == []
    end

    test "oversized input is rejected outright" do
      blob = String.duplicate("I always use tabs. ", 200)

      assert String.length(blob) > 1_500
      assert AutoExtract.extract(blob) == []
    end

    test "non-binary input is rejected" do
      assert AutoExtract.extract(nil) == []
      assert AutoExtract.extract(%{content: "I always use tabs"}) == []
    end

    test "empty and whitespace-only input is rejected" do
      assert AutoExtract.extract("") == []
      assert AutoExtract.extract("   \n  ") == []
    end
  end

  describe "extract/1 still captures genuine standing facts" do
    test "captures an explicit preference" do
      assert [%{type: :preference, content: content}] =
               AutoExtract.extract("I always use tabs for indentation in Go.")

      assert content == "I always use tabs for indentation in Go."
    end

    test "captures a decision" do
      assert [%{type: :decision, content: content}] =
               AutoExtract.extract("We decided to use Postgres for the primary store.")

      assert content =~ "Postgres"
    end

    test "captures a name" do
      assert [%{type: :identity, content: content}] = AutoExtract.extract("My name is Roberto.")
      assert content == "My name is Roberto."
    end

    test "captures a configuration fact" do
      assert [%{type: :fact, content: content}] =
               AutoExtract.extract("The database is deployed to us-east-1 on port 5432.")

      assert content =~ "us-east-1"
    end
  end

  describe "extract/1 stores only the matching sentence" do
    test "surrounding chatter is discarded" do
      message =
        "Hey, quick thing before we start. I always use tabs for indentation. " <>
          "Anyway, can you look at the build failure and tell me what broke?"

      assert [%{type: :preference, content: content}] = AutoExtract.extract(message)

      assert content == "I always use tabs for indentation."
      refute content =~ "build failure"
      refute content =~ "Hey, quick thing"
    end

    test "a matching sentence buried in a long message is bounded in size" do
      message = "Some lead-in. I always use tabs. " <> String.duplicate("filler words here. ", 20)

      assert [%{content: content}] = AutoExtract.extract(message)
      assert String.length(content) <= 300
    end
  end

  describe "machine_generated?/1" do
    test "flags subagent and system-authored text" do
      assert AutoExtract.machine_generated?("You are a code-review agent.")
      assert AutoExtract.machine_generated?("<system-reminder>do the thing</system-reminder>")
      assert AutoExtract.machine_generated?("Your job is to refute the claim.")
      assert AutoExtract.machine_generated?("[SHARED SCRATCHPAD] team directory")
    end

    test "does not flag ordinary human text" do
      refute AutoExtract.machine_generated?("I always use tabs for indentation.")
      refute AutoExtract.machine_generated?("can you fix the build please")
    end
  end
end
