defmodule OptimalSystemAgent.Agent.Loop.StreamIncompleteRecoveryTest do
  @moduledoc """
  P2 audit gap A: a provider stream that ends WITHOUT its own terminal marker
  (Ollama `done:true`, OpenAI-compat `[DONE]`, Anthropic `message_stop`) must
  not be delivered as a complete answer. These tests drive the REAL loop
  against `MockProvider`, opted into `:stream_incomplete` — the harness-level
  contract every real provider now flags (see `providers/ollama_test.exs`,
  `providers/openai_compat_test.exs`, `providers/anthropic_test.exs` for the
  provider-level reproduction of the raw stream parsing).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  @user_message "summarize the incident report"

  setup do
    prev = %{
      provider: Application.get_env(:optimal_system_agent, :default_provider),
      text: Application.get_env(:optimal_system_agent, :mock_provider_final_text),
      incomplete: Application.get_env(:optimal_system_agent, :mock_provider_stream_incomplete),
      max_iter: Application.get_env(:optimal_system_agent, :max_iterations)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 20)

    on_exit(fn ->
      restore(:default_provider, prev.provider)
      restore(:mock_provider_final_text, prev.text)
      restore(:mock_provider_stream_incomplete, prev.incomplete)
      restore(:max_iterations, prev.max_iter)
      Application.delete_env(:optimal_system_agent, :mock_provider_after_call_once)
      MockProvider.reset_stream_incomplete()
      MockProvider.reset_final_texts()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp sid, do: "stream-incomplete-#{System.unique_integer([:positive])}"

  defp base_state do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: sid(),
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      overflow_retries: 0,
      messages: [%{role: "user", content: @user_message}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  describe "nothing shown yet — a fresh retry, not a broken answer" do
    test "an empty stream_incomplete response is retried once, silently" do
      # Call 1 is cut off with nothing; call 2 (the retry) is a clean, normal
      # answer. `force_stream_incomplete_for(1)` flags only call 1.
      MockProvider.queue_final_texts(["", "The incident is resolved."])
      MockProvider.force_stream_incomplete_for(1)
      MockProvider.reset_round_trips()

      {response, state} = ReactLoop.run(base_state())

      assert response == "The incident is resolved."
      refute response =~ "INCOMPLETE"
      assert MockProvider.round_trips() == 2, "expected exactly one silent retry"
      assert Map.get(state, :recovery_attempts, 0) == 1
    end
  end

  describe "something already shown — deliver it marked, never re-run" do
    test "a stream_incomplete response WITH content is delivered marked, in one round-trip" do
      fragment = "Root cause: the disk filled up at"
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, fragment)
      Application.put_env(:optimal_system_agent, :mock_provider_stream_incomplete, true)

      MockProvider.reset_round_trips()
      {response, _state} = ReactLoop.run(base_state())

      assert response =~ fragment, "the partial answer must be preserved, not discarded"
      assert response =~ "INCOMPLETE"

      assert MockProvider.round_trips() == 1,
             "content already reached the user — a blind retry would duplicate it"
    end
  end

  describe "a clean finish is completely unaffected" do
    test "a normal (non-incomplete) response is delivered verbatim" do
      answer = "All clear, nothing further to report."
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, answer)
      Application.delete_env(:optimal_system_agent, :mock_provider_stream_incomplete)

      MockProvider.reset_round_trips()
      {response, _state} = ReactLoop.run(base_state())

      assert response == answer
      refute response =~ "INCOMPLETE"
      assert MockProvider.round_trips() == 1
    end
  end

  describe "the shared recovery budget bounds a persistently cut-off stream" do
    test "a stream that NEVER produces anything and NEVER sees a marker terminates, not loops" do
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "")
      Application.put_env(:optimal_system_agent, :mock_provider_stream_incomplete, true)

      MockProvider.reset_round_trips()
      {response, state} = ReactLoop.run(base_state())

      assert is_binary(response)
      assert response =~ "INCOMPLETE"

      # 1 initial attempt + @max_recovery_attempts(6) retries, then it stops —
      # never an unbounded loop (P2 audit gap C).
      assert MockProvider.round_trips() == 7

      assert Map.get(state, :recovery_attempts, 0) == 6
    end
  end
end
