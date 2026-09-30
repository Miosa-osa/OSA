defmodule OptimalSystemAgent.Agent.Loop.ReasoningWatchdogE2ETest do
  @moduledoc """
  End-to-end: a `MockProvider` stream that loops on its reasoning channel is
  caught LIVE, killed, and recovered — through the real `ReactLoop` /
  `LLMClient` pipeline (`MockProvider.queue_stream_events/1` replays raw
  streaming-callback events through the SAME callback a real provider
  drives), not a unit-level shortcut.

  Reproduces the incident this feature exists for: a generation looping
  short filler on its reasoning channel ("OK." repeated, never converging
  on a tool call or an answer) with nothing killing it until the watchdog
  exists to do so.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  @watchdog_key :reasoning_watchdog

  setup do
    prev = %{
      provider: Application.get_env(:optimal_system_agent, :default_provider),
      max_iter: Application.get_env(:optimal_system_agent, :max_iterations),
      watchdog: Application.get_env(:optimal_system_agent, @watchdog_key),
      advisor_enabled: Application.get_env(:optimal_system_agent, :advisor_enabled)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 30)

    # No real advisor call from a test — `watchdog_escalate/3` gates the
    # advisor pair behind `Advisor.enabled?/1`, so turning it off here
    # guarantees the escalation path retries the (mock) model itself instead
    # of reaching for whatever real credentials happen to be configured on
    # the machine this suite runs on.
    Application.put_env(:optimal_system_agent, :advisor_enabled, false)

    # Fast, deterministic thresholds for this suite — not the shipped
    # defaults (those are tuned against realistic streaming cadence and
    # would make an E2E test slow). `reasoning_watchdog_test.exs` owns
    # verifying the actual defaults.
    Application.put_env(:optimal_system_agent, @watchdog_key,
      enabled: true,
      check_every_chars: 8,
      repeated_phrase_threshold: 4,
      window_chars: 2_000,
      max_reasoning_ms: 3_600_000,
      max_reasoning_chars: 1_000_000
    )

    MockProvider.reset()
    MockProvider.reset_round_trips()
    MockProvider.reset_last_opts()
    MockProvider.reset_stream_events()
    MockProvider.reset_final_texts()

    on_exit(fn ->
      restore(:default_provider, prev.provider)
      restore(:max_iterations, prev.max_iter)
      restore(@watchdog_key, prev.watchdog)
      restore(:advisor_enabled, prev.advisor_enabled)
      Application.delete_env(:optimal_system_agent, :mock_provider_tool_calls)
      Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
      MockProvider.reset_stream_events()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp sid, do: "watchdog-e2e-#{System.unique_integer([:positive])}"

  defp base_state(session_id) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: session_id,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      overflow_retries: 0,
      messages: [%{role: "user", content: "investigate the flaky test"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  # A degenerate stream: the model loops short filler on its reasoning
  # channel and never calls a tool or answers — the exact incident shape.
  # Trailing `:done` so the call still terminates on its own if the watchdog
  # were somehow NOT to trip — the assertions below would then fail loudly
  # (wrong round-trip count) instead of the test hanging forever.
  defp looping_thinking_events(n \\ 20) do
    List.duplicate({:thinking_delta, "OK. "}, n) ++ [{:done, %{content: "", tool_calls: []}}]
  end

  defp clean_answer_events(text) do
    [{:text_delta, text}, {:done, %{content: text, tool_calls: []}}]
  end

  defp drain_pain_alerts(session_id, acc \\ []) do
    receive do
      {:osa_event, %{type: :system_event, event: :pain_alert, session_id: ^session_id} = p} ->
        drain_pain_alerts(session_id, [p | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  test "a looping stream is aborted mid-generation and retried with thinking disabled" do
    session_id = sid()
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    MockProvider.queue_stream_events([
      looping_thinking_events(),
      clean_answer_events("Found it, the flaky assertion races a background task.")
    ])

    {response, state} = ReactLoop.run(base_state(session_id))

    assert is_binary(response)
    assert response =~ "Found it"

    # Exactly two round-trips: the one that looped, and the retry that
    # answered — the watchdog did not let the loop run to a natural `:done`
    # (it would have taken 21 callback invocations' worth of a single
    # round-trip instead), and one retry was enough, no escalation needed.
    assert MockProvider.round_trips() == 2

    # The retry actually asked for thinking OFF — the 1.0.202 stop-loss
    # lever reused by the watchdog, not a second mechanism.
    assert Keyword.get(MockProvider.last_opts(), :thinking_disabled) == true

    # The shared per-turn recovery budget recorded exactly one spend, and the
    # watchdog's own escalation-stage counter cleared on the clean retry.
    assert Map.get(state, :recovery_attempts, 0) == 1
    assert Map.get(state, :watchdog_trips, 0) == 0

    # Visible: a :high trip alert naming the repeated phrase, then a
    # low-severity "resolved" notice once the retry landed.
    alerts = drain_pain_alerts(session_id)
    assert Enum.any?(alerts, &(&1.severity == "high" and &1.message =~ "OK."))
    assert Enum.any?(alerts, &(&1.message =~ "resolved"))
  end

  test "a SECOND consecutive degeneration escalates past the thinking-off retry" do
    session_id = sid()
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    MockProvider.queue_stream_events([
      looping_thinking_events(),
      looping_thinking_events(),
      clean_answer_events("Resolved on the third attempt.")
    ])

    {response, state} = ReactLoop.run(base_state(session_id))

    assert is_binary(response)
    assert response =~ "Resolved on the third attempt"

    assert MockProvider.round_trips() == 3
    assert Map.get(state, :recovery_attempts, 0) == 2
    assert Map.get(state, :watchdog_trips, 0) == 0

    alerts = drain_pain_alerts(session_id)
    assert Enum.any?(alerts, &(&1.severity == "high"))

    assert Enum.any?(
             alerts,
             &(&1.severity == "critical" and &1.message =~ "escalating")
           )
  end

  test "a degeneration that never stops is bounded by the shared recovery budget, never loops forever" do
    session_id = sid()

    # 8 consecutive looping calls — more than enough to exhaust the shared
    # per-turn recovery budget (6), which every watchdog trip spends from,
    # exactly like every OTHER recovery path (idle timeout, truncation, …).
    MockProvider.queue_stream_events(List.duplicate(looping_thinking_events(), 8))

    {response, state} = ReactLoop.run(base_state(session_id))

    assert is_binary(response)
    assert response =~ "recovery limit"

    # 1 initial + 6 retries = 7 — the SAME ceiling `recovery_budget_test.exs`
    # pins for every other recovery kind, never unbounded.
    assert MockProvider.round_trips() == 7
    assert Map.get(state, :recovery_attempts, 0) == 6
  end
end
