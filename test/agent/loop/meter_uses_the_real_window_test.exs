defmodule OptimalSystemAgent.Agent.Loop.MeterUsesTheRealWindowTest do
  @moduledoc """
  A 1M-window model gets its 1M: the status-bar meter divides by the model's
  real window, and compaction fires near that window rather than at a 200k
  ceiling.

  Reported live on `deepseek-v4.1-flash:cloud` (1,048,576-token window) at
  159.3k tokens:

      Context low (4% remaining) · Run /compact to compact & continue
      ⟐ deepseek-v4.1-flash:cloud │ ⣿⣿⣿⣿⣿⣿⢿░ 80% ctx

  Both readings were shares of a 200k operative window (159,300 / 200,000 =
  79.7%), and compaction fired at ~160k. On the model's own window that
  session was at 15%, with ~730k tokens to go before compaction was due.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.Telemetry

  @model "deepseek-v4.1-flash:cloud"
  @window 1_048_576

  defp pressure_at(tokens) do
    sid = "real-window-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")

    Telemetry.emit_context_pressure(%{
      session_id: sid,
      messages: [%{role: "user", content: "hi"}],
      last_input_tokens: tokens,
      model: @model,
      provider: :ollama_cloud
    })

    event =
      receive do
        {:osa_event, %{event: :context_pressure} = p} -> p
      after
        2_000 -> flunk("no context_pressure event")
      end

    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    event
  end

  test "a 1M-window model at 159.3k reads ~15%, not 80%" do
    event = pressure_at(159_300)

    assert event.model_context_window == @window,
           "precondition: the catalog window is 1M, got #{event.model_context_window}"

    assert event.max_tokens == @window,
           "max_tokens is #{event.max_tokens}, not the model's window"

    assert event.utilization < 20.0,
           "the meter reads #{event.utilization}% of a 1M window holding 159.3k"

    refute event.context_window_clamped
  end

  test "compaction is due near the real window, not at 167k" do
    event = pressure_at(159_300)

    assert event.compact_at == CompactionThresholds.compact_at(@window, @model)
    assert event.compact_at > 850_000, "compact_at is #{event.compact_at} on a 1M window"
    assert event.warn_at > 800_000

    refute event.context_low, "the low-context notice is up at 159.3k of 1M"
    refute event.above_compact
  end

  test "the warning band opens just below the compaction point" do
    event = pressure_at(880_000)

    assert event.context_low
    refute event.above_compact
    assert event.compact_at - 880_000 < 20_000
  end

  test "the homeostat's pressure signal reads the same window" do
    state = %{
      session_id: "homeostat-#{System.unique_integer([:positive])}",
      messages: [],
      last_input_tokens: 159_300,
      model: @model,
      provider: :ollama_cloud
    }

    assert_in_delta Telemetry.context_utilization(state), 159_300 / @window * 100, 0.1
  end
end
