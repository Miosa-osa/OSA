defmodule OptimalSystemAgent.Signal.OutputContractTest do
  @moduledoc """
  Unit tests for `OptimalSystemAgent.Signal.OutputContract` — the per-genre
  output contract applied to OSA's OWN answers (Signal Theory outbound,
  mirroring `Agent.Loop.GenreRouter`'s inbound genre routing).
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Signal.OutputContract

  describe "contract_for/1" do
    test "every genre in the fixed vocabulary has a non-empty contract" do
      for genre <- [:direct, :inform, :decide, :commit, :express] do
        contract = OutputContract.contract_for(genre)
        assert is_binary(contract)
        assert String.length(contract) > 0
      end
    end

    test "direct genre asks for actions, not narration" do
      assert OutputContract.contract_for(:direct) =~ ~r/action|step/i
    end

    test "inform genre asks for the answer first" do
      assert OutputContract.contract_for(:inform) =~ ~r/answer/i
    end

    test "decide genre asks for a recommendation plus tradeoffs" do
      contract = OutputContract.contract_for(:decide)
      assert contract =~ ~r/recommend/i
      assert contract =~ ~r/tradeoff/i
    end

    test "an unknown genre falls back to the direct contract" do
      assert OutputContract.contract_for(:not_a_genre) == OutputContract.contract_for(:direct)
    end

    test "every contract is tiny — a per-turn directive, not a second system prompt" do
      for genre <- [:direct, :inform, :decide, :commit, :express] do
        assert String.length(OutputContract.contract_for(genre)) < 220,
               "#{genre} contract is too long to be a cheap per-turn directive"
      end
    end
  end

  describe "genre_for/1" do
    test "classifies without raising and without an LLM call, for any string" do
      for msg <- ["do the thing now", "fyi the build passed", "thanks so much", ""] do
        assert OutputContract.genre_for(msg) in [:direct, :inform, :commit, :decide, :express]
      end
    end

    test "non-binary input falls back to :direct rather than raising" do
      assert OutputContract.genre_for(nil) == :direct
      assert OutputContract.genre_for(%{}) == :direct
    end
  end

  describe "directive_for/1" do
    test "wraps the classified genre's contract as a labelled, short string" do
      directive = OutputContract.directive_for("please run the tests now")
      assert is_binary(directive)
      assert String.length(directive) < 260
    end
  end
end
