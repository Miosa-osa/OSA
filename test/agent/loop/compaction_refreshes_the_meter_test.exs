defmodule OptimalSystemAgent.Agent.Loop.CompactionRefreshesTheMeterTest do
  @moduledoc """
  A completed compaction must update the number the meter is drawn from.

  Reported live: `/compact` folded 135.4k into 6.7k and the status bar went on
  reading `88% ctx` with `Context low (6% remaining)` underneath it. Both are
  computed from `state.last_input_tokens`, which is written only by
  `Accounting.maybe_put_last_input/2` after a provider round-trip — so a fold
  leaves the pre-compaction figure standing, and the meter keeps describing a
  conversation that no longer exists.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.Telemetry

  defp filler, do: String.duplicate("lorem ipsum dolor sit amet consectetur ", 60)

  defp conversation(turns) do
    Enum.flat_map(1..turns, fn i ->
      [
        %{role: "user", content: "turn #{i}: #{filler()}"},
        %{role: "assistant", content: "reply #{i}: #{filler()}"}
      ]
    end)
  end

  test "context pressure reports the folded conversation, not the pre-fold prompt size" do
    sid = "meter-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")

    folded = conversation(1)

    # The shape after a fold: history has been replaced, but `last_input_tokens`
    # still carries the size of the last request that was actually SENT.
    stale = %{
      session_id: sid,
      messages: folded,
      last_input_tokens: 135_400,
      model: "grok-4.6",
      provider: :xai
    }

    Telemetry.emit_context_pressure(stale)

    stale_event =
      receive do
        {:osa_event, %{event: :context_pressure} = p} -> p
      after
        2_000 -> flunk("no context_pressure event")
      end

    assert stale_event.estimated_tokens == 135_400,
           "precondition: the stale field is what the meter reads"

    # What the fix does: refresh the field from the conversation that now
    # exists, then re-emit.
    refreshed = %{stale | last_input_tokens: Compactor.estimate_tokens(folded)}
    Telemetry.emit_context_pressure(refreshed)

    fresh_event =
      receive do
        {:osa_event, %{event: :context_pressure} = p} -> p
      after
        2_000 -> flunk("no second context_pressure event")
      end

    assert fresh_event.estimated_tokens == Compactor.estimate_tokens(folded)

    assert fresh_event.estimated_tokens < stale_event.estimated_tokens,
           "the refreshed reading is not smaller than the stale one"

    assert fresh_event.utilization < stale_event.utilization,
           "the meter percentage did not fall after the fold: " <>
             "#{stale_event.utilization}% -> #{fresh_event.utilization}%"

    refute fresh_event.context_low,
           "the low-context banner is still raised on a conversation of " <>
             "#{fresh_event.estimated_tokens} tokens"

    assert fresh_event.percent_left > stale_event.percent_left,
           "percent_left did not recover after the fold: " <>
             "#{stale_event.percent_left}% -> #{fresh_event.percent_left}%"

    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
  end
end
