defmodule OptimalSystemAgent.Providers.StopReasonTest do
  @moduledoc """
  Every provider's spelling of "you ran out of output tokens".

  The defect this module exists to close: `ReactLoop` matched on Anthropic's
  `"max_tokens"` (and, on one clause, OpenAI's `"length"`), so on Ollama —
  OSA's DEFAULT provider — a truncated generation was indistinguishable from a
  finished one and was delivered to the user as the final answer. MEASURED on
  `bench/terminalbench/runs/osa-tb20-full89-f6981b61`: `regex-chess` handed the
  grader a mid-sentence fragment after a generation that stopped at exactly
  32,768 output tokens.

  These are the spellings, per provider, that must all mean the same thing.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.StopReason

  doctest OptimalSystemAgent.Providers.StopReason

  describe "normalize/1 — truncation, per provider" do
    test "every provider's truncation spelling maps to :truncated" do
      # provider => the value it puts on the wire when it hits the ceiling
      wire = %{
        anthropic: "max_tokens",
        openai_compat: "length",
        openai_responses: "max_output_tokens",
        ollama: "length",
        gemini: "MAX_TOKENS",
        bedrock: "max_tokens",
        cohere: "MAX_TOKENS"
      }

      for {provider, value} <- wire do
        assert StopReason.normalize(value) == :truncated,
               "#{provider} reports #{inspect(value)} on truncation and it did not " <>
                 "normalize to :truncated — the loop will deliver a fragment as an answer"
      end
    end

    test "matching is case- and whitespace-insensitive" do
      for v <- ["MAX_TOKENS", "Max_Tokens", " length ", "LENGTH"] do
        assert StopReason.normalize(v) == :truncated
      end
    end
  end

  describe "normalize/1 — everything that is NOT truncation" do
    test "clean stops" do
      for v <- ["stop", "end_turn", "STOP", "stop_sequence", "COMPLETE"] do
        assert StopReason.normalize(v) == :stop, "#{v} must not be read as truncation"
      end
    end

    test "tool-call stops" do
      for v <- ["tool_calls", "tool_use", "TOOL_CALL"] do
        assert StopReason.normalize(v) == :tool_calls
      end
    end

    test "filtered and errored stops are their own buckets" do
      assert StopReason.normalize("content_filter") == :content_filter
      assert StopReason.normalize("SAFETY") == :content_filter
      assert StopReason.normalize("guardrail_intervened") == :content_filter
      assert StopReason.normalize("error") == :error
    end

    test "absent / unknown is :unknown and NOT :stop" do
      # These are different facts. Collapsing "the provider did not tell us"
      # into "the model finished" is exactly how a truncation becomes an answer.
      for v <- [nil, "", "  ", 42, :some_new_reason, %{}] do
        assert StopReason.normalize(v) == :unknown, "#{inspect(v)} must be :unknown"
      end
    end

    test "canonical atoms round-trip" do
      for a <- [:truncated, :stop, :tool_calls, :content_filter, :error, :unknown] do
        assert StopReason.normalize(a) == a
      end
    end
  end

  describe "truncated?/1" do
    test "reads a response map with either key style" do
      assert StopReason.truncated?(%{content: "…", stop_reason: "length"})
      assert StopReason.truncated?(%{"content" => "…", "stop_reason" => "MAX_TOKENS"})
    end

    test "a normal completion is not truncated" do
      refute StopReason.truncated?(%{content: "done", stop_reason: "stop"})
      refute StopReason.truncated?(%{content: "done", stop_reason: "end_turn"})
      refute StopReason.truncated?(%{content: "", stop_reason: "tool_calls"})
    end

    test "a response with no stop reason at all is not truncated" do
      refute StopReason.truncated?(%{content: "done", tool_calls: []})
      refute StopReason.truncated?(%{content: "done", stop_reason: nil})
    end

    test "accepts a bare reason too" do
      assert StopReason.truncated?("length")
      refute StopReason.truncated?("stop")
      refute StopReason.truncated?(nil)
    end
  end

  describe "raw/1" do
    test "reports the provider's own word, not OSA's bucket" do
      assert StopReason.raw(%{stop_reason: "MAX_TOKENS"}) == "MAX_TOKENS"
      assert StopReason.raw(%{"stop_reason" => "length"}) == "length"
      assert StopReason.raw("max_output_tokens") == "max_output_tokens"
      assert StopReason.raw(%{content: "x"}) == nil
    end
  end
end
