defmodule OptimalSystemAgent.Agent.Loop.MeterUsesTheRealWindowTest do
  @moduledoc """
  The status-bar meter divides by the model's real window, and the compaction
  point travels beside it as an absolute token count.

  Reported live on `deepseek-v4.1-flash:cloud` (1,048,576-token window) at
  159.3k tokens:

      Context low (4% remaining) · Run /compact to compact & continue
      ⟐ deepseek-v4.1-flash:cloud │ ⣿⣿⣿⣿⣿⣿⢿░ 80% ctx

  Both readings were shares of the 200k operative window (the compaction
  budget): 159,300 / 200,000 = 79.7%. On the model's own window that session
  was at 15%.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.Telemetry

  @model "deepseek-v4.1-flash:cloud"

  defp pressure_at(tokens, provider) do
    sid = "real-window-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")

    Telemetry.emit_context_pressure(%{
      session_id: sid,
      messages: [%{role: "user", content: "hi"}],
      last_input_tokens: tokens,
      model: @model,
      provider: provider
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
    event = pressure_at(159_300, :ollama_cloud)

    assert event.model_context_window == 1_048_576,
           "precondition: the catalog window is 1M, got #{event.model_context_window}"

    assert event.max_tokens == event.model_context_window,
           "max_tokens is the compaction budget (#{event.max_tokens}), not the window"

    assert event.utilization < 20.0,
           "the meter reads #{event.utilization}% of a 1M window holding 159.3k"

    assert event.context_window_clamped
  end

  test "the compaction point still comes from the operative window" do
    event = pressure_at(159_300, :ollama_cloud)

    assert event.compact_at == CompactionThresholds.compact_at(1_048_576, @model)
    assert event.warn_at == CompactionThresholds.warn_at(1_048_576, @model)
    assert event.compact_at < event.max_tokens

    # 159.3k is inside the warning band, so the notice is up, even though the
    # meter now reads low: the two answer different questions.
    assert event.context_low
    refute event.above_compact
  end

  test "the homeostat keeps regulating on pressure toward compaction" do
    state = %{
      session_id: "homeostat-#{System.unique_integer([:positive])}",
      messages: [],
      last_input_tokens: 159_300,
      model: @model,
      provider: :ollama_cloud
    }

    # 159.3k of the 200k operative window, not of the 1M window: the
    # homeostat's 85% band has to be reachable before compaction fires.
    assert_in_delta Telemetry.context_utilization(state), 79.7, 0.1
  end
end
