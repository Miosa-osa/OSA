defmodule OptimalSystemAgent.Agent.Loop.LLMClientHistoryRepairTest do
  @moduledoc """
  Reproduces the audit-item-1 defect through the REAL `LLMClient` entry
  points: a corrupted transcript (an orphan tool call with no result) is
  sent to the provider unchanged, the provider 400s with a request-shape
  error (`ids were found without` → `:tool_use_mismatch`), and — before the
  fix — nothing ever repaired it, so the identical 400 would repeat on
  every subsequent turn once the corrupted shape was persisted.

  Pins two things:

    1. `llm_chat/3` / `llm_chat_stream/3` sanitize BEFORE the first request —
       a corrupted history never reaches the provider in the first place.
    2. `maybe_repair_history_and_retry/4` is a SAFE one-shot: because the
       pre-flight pass already ran `HistorySanitizer.sanitize/2` on the exact
       same `messages`, and `sanitize/2` is a pure function, a request-shape
       400 that reaches this stage means the corruption is NOT one this
       version of `HistorySanitizer` can fix — re-running it produces the
       identical result, and the guard (`{^messages, _} -> error`) MUST
       decline to retry rather than loop pointlessly. This is what stops
       item 1's "the same 400 then repeats every turn" from becoming "the
       same 400 repeats every ATTEMPT of the same turn" instead.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()
    MockProvider.reset_round_trips()

    on_exit(fn ->
      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      Application.delete_env(:optimal_system_agent, :mock_provider_error)
    end)

    :ok
  end

  defp state do
    %{
      provider: :mock,
      model: "mock-model-1.0",
      session_id: "llmc-repair-#{System.unique_integer([:positive])}"
    }
  end

  @orphan_tc %{id: "tc_orphan", name: "shell_execute", arguments: %{}}
  @corrupted_messages [
    %{role: "user", content: "run it"},
    %{role: "assistant", content: "on it", tool_calls: [@orphan_tc]}
  ]
  @tool_use_mismatch_reason "Anthropic returned 400: the following tool_use ids were found " <>
                              "without tool_result blocks immediately after: tc_orphan."

  describe "pre-flight sanitize — the corrupted body never reaches the provider" do
    test "the provider sees a repaired (filled) tool_use, not the orphan" do
      Application.put_env(:optimal_system_agent, :mock_provider_error, fn messages ->
        # Fail the call unless the orphan has already been filled by the
        # PRE-FLIGHT pass — proves llm_chat/3 sanitized before sending.
        if Enum.any?(messages, &(Map.get(&1, :tool_call_id) == "tc_orphan")) do
          nil
        else
          @tool_use_mismatch_reason
        end
      end)

      assert {:ok, _result} = LLMClient.llm_chat(state(), @corrupted_messages, [])

      assert MockProvider.round_trips() == 1,
             "the pre-flight sanitizer should have fixed it on the FIRST attempt"
    end

    test "the streaming path gets the identical pre-flight repair" do
      Application.put_env(:optimal_system_agent, :mock_provider_error, fn messages ->
        if Enum.any?(messages, &(Map.get(&1, :tool_call_id) == "tc_orphan")),
          do: nil,
          else: @tool_use_mismatch_reason
      end)

      full_state = %{
        session_id: "llmc-repair-stream-#{System.unique_integer([:positive])}",
        provider: :mock,
        model: "mock-model-1.0"
      }

      assert {:ok, _result} = LLMClient.llm_chat_stream(full_state, @corrupted_messages, [])
      assert MockProvider.round_trips() == 1
    end
  end

  describe "the one-shot repair-and-retry guard never loops pointlessly" do
    test "a repairable-category 400 on an ALREADY-clean body is surfaced, not retried forever" do
      # `@corrupted_messages` is repaired by the pre-flight pass before this
      # ever runs, so by the time the provider is called the body is already
      # clean. A provider that STILL rejects it with a repairable-category
      # reason (simulating a corruption pattern this HistorySanitizer version
      # cannot fix) gives the retry function nothing NEW to change —
      # `HistorySanitizer.sanitize/2` is pure, so re-running it on the same
      # already-clean input can only return the same input. The guard must
      # recognize that and give up after exactly one attempt, not spin.
      Application.put_env(:optimal_system_agent, :mock_provider_error, @tool_use_mismatch_reason)

      assert {:error, reason} = LLMClient.llm_chat(state(), @corrupted_messages, [])
      assert reason == @tool_use_mismatch_reason
      assert MockProvider.round_trips() == 1
    end

    test "a DIFFERENT corruption class (duplicate tool_call ids) is out of scope and never retried" do
      # `:duplicate_tool_use` is not in `@repairable_categories` —
      # `HistorySanitizer` drops/fills/merges tool_use↔tool_result pairing and
      # empty text; it has no id-deduplication pass, so this category is
      # deliberately excluded rather than attempted-and-declined.
      dup_tc_a = %{id: "tc_dup", name: "shell_execute", arguments: %{cmd: "ls"}}
      dup_tc_b = %{id: "tc_dup", name: "shell_execute", arguments: %{cmd: "pwd"}}

      messages = [
        %{role: "assistant", content: "", tool_calls: [dup_tc_a]},
        %{role: "tool", tool_call_id: "tc_dup", content: "file listing"},
        %{role: "assistant", content: "", tool_calls: [dup_tc_b]},
        %{role: "tool", tool_call_id: "tc_dup", content: "/home"}
      ]

      Application.put_env(
        :optimal_system_agent,
        :mock_provider_error,
        "Anthropic returned 400: tool_use ids must be unique"
      )

      assert {:error, _reason} = LLMClient.llm_chat(state(), messages, [])
      assert MockProvider.round_trips() == 1
    end

    test "a non-repairable category (a plain 400 the sanitizer has no opinion on) is never touched by this path" do
      Application.put_env(
        :optimal_system_agent,
        :mock_provider_error,
        "Anthropic returned 400: something else entirely wrong with the request"
      )

      assert {:error, _reason} = LLMClient.llm_chat(state(), @corrupted_messages, [])
      assert MockProvider.round_trips() == 1
    end
  end
end
