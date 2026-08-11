defmodule OptimalSystemAgent.Conversations.IntegrityTest do
  @moduledoc """
  Both of these subsystems turn model output into something a later reader
  treats as fact, and both had ways of manufacturing that fact out of nothing.

    * `Weaver.parse_summary/2` answered a decode failure with a fully-empty but
      well-formed summary, indistinguishable from a real one, which
      `parse_and_store/2` then wrote to memory as canonical: "this conversation
      reached no decisions" recorded as knowledge.
    * `Weaver.format_transcript/1` truncated to the FIRST 12,000 characters —
      discarding exactly the later turns being summarised — with no signal.
    * `Debate.consensus_met?/1` read `List.last/1` over the whole tally, so a
      voter that failed the final round still contributed its previous score
      and still counted toward `voter_count`.
    * `Debate.parse_score/1` fell back to the first bare digit anywhere in the
      reply, so "against the 3 criteria" was recorded as a vote of 3.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Conversations.Debate
  alias OptimalSystemAgent.Conversations.Weaver

  defp conversation_state do
    %{
      id: "conv-1",
      topic: "whether to migrate",
      type: :debate,
      participants: [%{name: "a", role: "x"}, %{name: "b", role: "y"}],
      turn_count: 4
    }
  end

  describe "Weaver.parse_summary/2" do
    test "a decode failure is distinguishable from a genuinely empty summary" do
      {:ok, degraded} = Weaver.parse_summary("I could not comply.", conversation_state())
      assert degraded.degraded == true

      {:ok, real} =
        Weaver.parse_summary(
          ~s({"key_decisions": [], "action_items": [], "dissenting_views": [], "open_questions": [], "summary": "nothing was decided"}),
          conversation_state()
        )

      assert real.degraded == false

      # The two carry identical content — only the flag tells them apart, which
      # is precisely what the store path needs.
      assert degraded.key_decisions == real.key_decisions
      refute degraded.degraded == real.degraded
    end
  end

  describe "Weaver.format_transcript/1" do
    test "truncation keeps the end of the conversation, where the conclusions are" do
      filler = String.duplicate("x", 20_000)

      transcript = [
        {"alice", "OPENING_STATEMENT " <> filler, nil},
        {"bob", "FINAL_DECISION we ship on Tuesday", nil}
      ]

      out = Weaver.format_transcript(transcript)

      assert out =~ "OPENING_STATEMENT"
      assert out =~ "FINAL_DECISION we ship on Tuesday"
      assert out =~ "omitted"
    end

    test "short transcripts are passed through untouched" do
      out = Weaver.format_transcript([{"alice", "hi", nil}, {"bob", "hello", nil}])
      assert out == "alice:\nhi\n\nbob:\nhello"
    end
  end

  describe "Debate.consensus_met?/1" do
    test "a round in which every voter failed is not consensus" do
      state = %{
        round_votes: %{1 => %{"v1" => 9, "v2" => 8}},
        consensus_policy: :majority,
        round: 2
      }

      refute Debate.consensus_met?(state),
             "round 1's scores were counted as if they were round 2's"
    end

    test "a voter that did not score this round is excluded from the denominator" do
      # v2 failed in round 2; only v1 voted, and it passed.
      state = %{
        round_votes: %{1 => %{"v1" => 3, "v2" => 3}, 2 => %{"v1" => 9}},
        consensus_policy: :unanimous,
        round: 2
      }

      assert Debate.consensus_met?(state)
    end

    test "a failing current round is not rescued by a passing earlier one" do
      state = %{
        round_votes: %{1 => %{"v1" => 9, "v2" => 9}, 2 => %{"v1" => 2, "v2" => 1}},
        consensus_policy: :majority,
        round: 2
      }

      refute Debate.consensus_met?(state)
    end
  end

  describe "Debate.parse_score/1" do
    test "an explicit JSON score is used" do
      assert {:ok, 7} = Debate.parse_score(~s({"score": 7}))
    end

    test "prose containing an incidental number is not scraped as a vote" do
      assert {:error, :parse_failed} =
               Debate.parse_score("I evaluated the proposal against the 3 criteria you gave me.")

      assert {:error, :parse_failed} = Debate.parse_score("I have 0 objections to this plan.")
    end

    test "a number the model actually labelled as a score is still accepted" do
      assert {:ok, 8} = Debate.parse_score("My score: 8 out of 10.")
    end
  end
end
