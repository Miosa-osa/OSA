defmodule OptimalSystemAgent.Agent.Loop.Regulation.PainTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Regulation.Pain
  alias OptimalSystemAgent.Agent.Loop.Regulation.PainChannel

  @key :regulation_pain

  setup do
    original = Application.get_env(:optimal_system_agent, @key)

    Application.put_env(:optimal_system_agent, @key,
      enabled: true,
      low_at: 0.15,
      medium_at: 0.35,
      question_at: 0.55,
      pause_at: 0.85,
      min_emit_interval_ms: 5_000,
      wait_alarm_ms: 60_000
    )

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:optimal_system_agent, @key),
        else: Application.put_env(:optimal_system_agent, @key, original)
    end)

    :ok
  end

  defp sid, do: "pain-#{System.unique_integer([:positive])}"

  defp signals(overrides \\ []) do
    Map.merge(
      %{
        probe_streak: 0,
        probe_tool: nil,
        stall_checkpoints: 0,
        reasoning_only_streak: 0,
        recovery_attempts: 0,
        recovery_ratio: 0.0,
        graded_escalation: 0,
        escalation_ratio: 0.0,
        reasoning_overflow_ms: nil,
        wait_ms: 0,
        surprises: 0,
        no_disk_change?: true,
        elapsed_ms: 12_000,
        cost_this_turn_usd: 0.0
      },
      Map.new(overrides)
    )
  end

  defp homeostat_report(overrides \\ []) do
    Map.merge(
      %{
        context: %{value: 10.0, band: :ok, corrected?: false},
        cost: %{value: 0.0, band: :ok},
        progress: %{idle_streak: 0, band: :ok, nudged?: false},
        error: %{ratio: 0.0, band: :ok}
      },
      Map.new(overrides)
    )
  end

  defp drain(session_id, acc \\ []) do
    receive do
      {:osa_event, %{type: :system_event, event: :pain_alert, session_id: ^session_id} = p} ->
        drain(session_id, [p | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "severity bands" do
    test "no signal at all reads :none and never surfaces" do
      session_id = sid()
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}

      {:ok, result_state} = Pain.evaluate(state, signals(), homeostat_report())
      assert Map.delete(result_state, :regulation_last_reported_severity) == state
      assert drain(session_id) == []
    end

    test "a maxed-out probe streak plus a couple of secondary signals reaches :high but not :critical" do
      session_id = sid()
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}

      {:ok, _state} =
        Pain.evaluate(
          state,
          signals(probe_streak: 5, escalation_ratio: 1.0, surprises: 3, wait_ms: 60_000),
          homeostat_report()
        )

      [alert] = drain(session_id)
      assert alert.severity == "high"
    end

    test "several strong signals together reach :critical and pause the turn" do
      session_id = sid()
      state = %{session_id: session_id}

      severe =
        signals(
          probe_streak: 5,
          reasoning_only_streak: 5,
          recovery_ratio: 1.0,
          escalation_ratio: 1.0,
          surprises: 3,
          reasoning_overflow_ms: 90_000
        )

      report =
        homeostat_report(cost: %{value: 1.0, band: :high}, error: %{ratio: 1.0, band: :high})

      assert {:halt, message, halted_state} = Pain.evaluate(state, severe, report)
      assert halted_state.session_id == session_id
      assert message =~ "Pausing here"
    end
  end

  describe "cause_text (surfaced via the broadcast message)" do
    test "leads with the probe repeat when that is the dominant signal" do
      session_id = sid()
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}

      Pain.evaluate(
        state,
        signals(probe_streak: 4, probe_tool: "file_read", no_disk_change?: true),
        homeostat_report()
      )

      [alert] = drain(session_id)
      assert alert.message =~ "file_read"
      assert alert.message =~ "no edits"
    end

    test "leads with cost-without-progress when the homeostat flagged it and nothing else dominates" do
      session_id = sid()
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}

      Pain.evaluate(
        state,
        signals(escalation_ratio: 1.0),
        homeostat_report(cost: %{value: 0.42, band: :high})
      )

      [alert] = drain(session_id)
      assert alert.message =~ "0.42"
      assert alert.message =~ "nothing changed on disk"
    end
  end

  describe "rate limiting (delegated to PainChannel)" do
    test "a second emission at the SAME severity within the window is suppressed" do
      session_id = sid()
      PainChannel.clear(session_id)
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}
      sig = signals(probe_streak: 4)

      Pain.evaluate(state, sig, homeostat_report())
      assert length(drain(session_id)) == 1

      Pain.evaluate(state, sig, homeostat_report())
      assert drain(session_id) == [], "rate limit should have suppressed the repeat"
    end

    test "a severity INCREASE always bypasses the rate limit" do
      session_id = sid()
      PainChannel.clear(session_id)
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}

      Pain.evaluate(state, signals(probe_streak: 4), homeostat_report())
      assert length(drain(session_id)) == 1

      Pain.evaluate(
        state,
        signals(probe_streak: 5, reasoning_only_streak: 5, surprises: 3),
        homeostat_report()
      )

      [alert] = drain(session_id)
      assert alert.severity in ["high", "critical"]
    end
  end

  describe "clearing a resolved alert" do
    test "dropping back to :none broadcasts a clear so the TUI row does not go stale" do
      session_id = sid()
      PainChannel.clear(session_id)
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")
      state = %{session_id: session_id}

      {:ok, state} = Pain.evaluate(state, signals(probe_streak: 4), homeostat_report())
      assert length(drain(session_id)) == 1

      {:ok, _state} = Pain.evaluate(state, signals(), homeostat_report())
      [clear_alert] = drain(session_id)
      assert clear_alert.severity == "none"
    end
  end

  describe "steering: ask one question" do
    test "high severity caused by ambiguity injects exactly one question directive" do
      state = %{session_id: sid(), messages: []}

      ambiguous_high =
        signals(probe_streak: 5, escalation_ratio: 1.0, surprises: 3, wait_ms: 60_000)

      {:ok, state} = Pain.evaluate(state, ambiguous_high, homeostat_report())

      assert state.regulation_question_asked == true
      assert Enum.count(state.messages, &(&1.role == "system")) == 1

      # Calling again this turn must not stack a second question.
      {:ok, state2} = Pain.evaluate(state, ambiguous_high, homeostat_report())

      assert Enum.count(state2.messages, &(&1.role == "system")) == 1
    end

    test "high severity NOT caused by ambiguity does not inject a question" do
      state = %{session_id: sid(), messages: []}

      non_ambiguous_high =
        signals(
          reasoning_only_streak: 5,
          escalation_ratio: 1.0,
          recovery_ratio: 1.0,
          reasoning_overflow_ms: 90_000
        )

      report =
        homeostat_report(cost: %{value: 1.0, band: :high}, error: %{ratio: 1.0, band: :high})

      {:ok, state} = Pain.evaluate(state, non_ambiguous_high, report)

      refute Map.get(state, :regulation_question_asked, false)
      assert state.messages == []
    end
  end
end
