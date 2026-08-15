defmodule OptimalSystemAgent.Agent.Loop.TruncatedResponseTest do
  @moduledoc """
  A generation that hit the output ceiling must never be delivered as the answer.

  MEASURED, `bench/terminalbench/runs/osa-tb20-full89-f6981b61`:

    * `regex-chess` — the final generation is exactly 32,768 output tokens
      after a 350,880-character thinking block. The truncated mid-sentence text
      WAS delivered as the answer and `/app/re.json`, the deliverable, was
      never written.
    * `schemelike-metacircular-eval` — the last three generations are all
      exactly 32,768, and the reasoning-only doom-loop guard reported those
      three truncations as "3 consecutive generations produced no tool calls",
      then emitted its own advice text as the final answer.

  Root cause: `ReactLoop` matched Anthropic's `"max_tokens"` spelling only, and
  the provider in use (Ollama) never reported a stop reason at all.

  These tests drive the REAL loop against a mock provider pinned to a
  truncation stop reason. Live verification is blocked (Ollama at its session
  usage limit, every key in `.env` empty), so the provider is synthetic — but
  the loop, the guard and the delivered answer are the real ones.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  # A sentence cut off mid-clause — the exact shape `regex-chess` delivered.
  @fragment "Let me investigate the en-passant behavior in python-chess and understand the"

  @user_message "solve the chess position encoding task"

  setup do
    prev = %{
      provider: Application.get_env(:optimal_system_agent, :default_provider),
      text: Application.get_env(:optimal_system_agent, :mock_provider_final_text),
      stop: Application.get_env(:optimal_system_agent, :mock_provider_stop_reason),
      max_iter: Application.get_env(:optimal_system_agent, :max_iterations),
      max_tok: Application.get_env(:optimal_system_agent, :max_response_tokens)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 12)
    # A truncation continuation bumps this in the process dictionary; clear it
    # so one test cannot inherit another's bumped ceiling.
    Process.delete(:osa_bumped_max_tokens)

    on_exit(fn ->
      restore(:default_provider, prev.provider)
      restore(:mock_provider_final_text, prev.text)
      restore(:mock_provider_stop_reason, prev.stop)
      restore(:max_iterations, prev.max_iter)
      restore(:max_response_tokens, prev.max_tok)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp sid, do: "truncation-#{System.unique_integer([:positive])}"

  # A plain map (not the struct) because the loop `Map.put/3`s keys the struct
  # does not declare (`:turn_truncated`, `:truncations`, …).
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

  defp run_with(text, stop_reason) do
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, text)

    if stop_reason,
      do: Application.put_env(:optimal_system_agent, :mock_provider_stop_reason, stop_reason),
      else: Application.delete_env(:optimal_system_agent, :mock_provider_stop_reason)

    MockProvider.reset_round_trips()
    {response, state} = ReactLoop.run(base_state())
    {response, state, MockProvider.round_trips()}
  end

  # ── The defect ────────────────────────────────────────────────────────────

  describe "a truncated generation is never delivered as a complete answer" do
    for {provider, spelling} <- [
          {"Ollama / OpenAI-compat", "length"},
          {"Anthropic / Bedrock", "max_tokens"},
          {"Gemini / Cohere", "MAX_TOKENS"},
          {"OpenAI Responses", "max_output_tokens"}
        ] do
      test "#{provider} (#{spelling}) — the fragment is marked incomplete" do
        {response, _state, _n} = run_with(@fragment, unquote(spelling))

        assert is_binary(response)

        assert response =~ "INCOMPLETE",
               "a generation that stopped at the output ceiling (stop_reason=" <>
                 "#{unquote(spelling)}) was delivered verbatim as the final answer. " <>
                 "Got: #{inspect(response)}"

        assert response =~ unquote(spelling),
               "the marker must name the provider's OWN stop reason so the cause is " <>
                 "readable without correlating logs"
      end
    end

    test "the model's partial text is preserved, not discarded" do
      # The fragment is usually most of a real answer. Throwing it away loses
      # genuine work; what must not survive is the impression it is finished.
      {response, _state, _n} = run_with(@fragment, "length")

      assert response =~ @fragment
    end

    test "the loop attempts continuation before giving up" do
      {_response, _state, n} = run_with(@fragment, "length")

      assert n > 1,
             "a truncated generation must be CONTINUED, not accepted — the loop " <>
               "made only #{n} provider round-trip(s)"

      # Bounded: output tokens are the expensive half of a request, and an
      # unbounded continuation on a runaway generation is real money.
      assert n <= 4,
             "continuation must be bounded; the loop made #{n} round-trips"
    end

    test "the turn records the truncation for telemetry" do
      {_response, state, _n} = run_with(@fragment, "length")

      assert Map.get(state, :truncations, 0) > 0,
             "`turn_end` reports `truncations` next to `effort` and `reasoning`; " <>
               "the counter was never set"

      assert OptimalSystemAgent.Observability.truncation_count(state) > 0
    end
  end

  # ── The control ───────────────────────────────────────────────────────────

  describe "a normal completion is unaffected" do
    test "a clean stop is delivered verbatim in one round-trip" do
      answer = "The encoding uses a 64-character board string. Done."

      {response, state, n} = run_with(answer, "stop")

      assert response == answer
      refute response =~ "INCOMPLETE"
      assert n == 1, "a complete answer must cost exactly one round-trip, cost #{n}"
      assert Map.get(state, :truncations, 0) == 0
    end

    test "a provider that reports NO stop reason is still delivered verbatim" do
      # Absence must not be read as truncation — that would re-issue every
      # generation from claude_cli / copilot_cli / Replicate forever.
      answer = "The encoding uses a 64-character board string. Done."

      {response, _state, n} = run_with(answer, nil)

      assert response == answer
      refute response =~ "INCOMPLETE"
      assert n == 1
    end

    test "`end_turn` and `tool_calls` are not truncation" do
      answer = "All set."

      for reason <- ["end_turn", "tool_calls", "STOP", "COMPLETE"] do
        {response, _state, _n} = run_with(answer, reason)

        assert response == answer,
               "stop_reason=#{reason} must not be treated as truncation"
      end
    end
  end
end
