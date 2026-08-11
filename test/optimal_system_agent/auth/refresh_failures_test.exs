defmodule OptimalSystemAgent.Auth.RefreshFailuresTest do
  @moduledoc """
  Deleting a stored credential is the most destructive thing the auth surface
  does without asking: the user cannot undo it and has to walk the whole
  sign-in again, usually mid-conversation and without understanding why.

  That decision used to be spelled three different ways for one question —
  `OpenAICodex` took two consecutive rejections, `Copilot` took one, and
  `XAI`/`Qwen`/`MiniMax` never deleted at all — and only one of the three had
  a reason attached. These tests pin the single rule.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.RefreshFailures

  setup do
    for id <- ~w(test_a test_b copilot openai_codex xai qwen minimax) do
      RefreshFailures.reset(id)
    end

    :ok
  end

  describe "the two-strike rule" do
    test "one rejection does not sign out; the second does" do
      # The whole point: providers return `invalid_grant` for transient
      # reasons, and one bad minute must not end the session.
      refute RefreshFailures.record_and_sign_out?("test_a")
      assert RefreshFailures.record_and_sign_out?("test_a")
    end

    test "the strikes must be CONSECUTIVE — a success in between clears them" do
      refute RefreshFailures.record_and_sign_out?("test_a")
      RefreshFailures.reset("test_a")

      # A rejection now and another after a hundred good turns is not
      # evidence of a dead grant.
      refute RefreshFailures.record_and_sign_out?("test_a"),
             "a rejection separated from an earlier one by a success must not sign the user out"
    end

    test "signing out clears the count, so the NEXT credential starts at zero" do
      refute RefreshFailures.record_and_sign_out?("test_a")
      assert RefreshFailures.record_and_sign_out?("test_a")

      assert RefreshFailures.count("test_a") == 0,
             "strikes against a deleted credential are meaningless and must not carry over"

      refute RefreshFailures.record_and_sign_out?("test_a")
    end

    test "counts are per provider — a flaky GitHub cannot sign you out of OpenAI" do
      refute RefreshFailures.record_and_sign_out?("test_a")
      refute RefreshFailures.record_and_sign_out?("test_b")

      assert RefreshFailures.count("test_a") == 1
      assert RefreshFailures.count("test_b") == 1
    end

    test "atom and string provider ids address the same counter" do
      refute RefreshFailures.record_and_sign_out?(:test_a)
      assert RefreshFailures.count("test_a") == 1
    end
  end

  describe "handle_rejection/3" do
    test "does not delete on the first rejection, and does on the second" do
      deletes = :counters.new(1, [])
      delete = fn -> :counters.add(deletes, 1, 1) end

      refute RefreshFailures.handle_rejection("test_a", "Test Provider", delete)

      assert :counters.get(deletes, 1) == 0,
             "a single rejection must never delete the credential"

      assert RefreshFailures.handle_rejection("test_a", "Test Provider", delete)
      assert :counters.get(deletes, 1) == 1
    end
  end
end
