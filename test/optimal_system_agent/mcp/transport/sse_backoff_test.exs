defmodule OptimalSystemAgent.MCP.Transport.SSEBackoffTest do
  @moduledoc """
  Backoff-timing tests for the rapid-death reconnect throttle (grok's SSE
  `mcp_http_client.rs` port). Verifies that stable deaths reset the delay while
  rapid / never-connected deaths escalate it geometrically, capped at `max_ms`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Transport.SSEBackoff

  test "a server that never connects escalates geometrically, capped at max_ms" do
    throttle = SSEBackoff.new(base_ms: 1_000, max_ms: 30_000)

    {delays, _final} =
      Enum.map_reduce(1..8, throttle, fn _i, t ->
        {delay, t} = SSEBackoff.observe_death(t, false)
        {delay, t}
      end)

    # base*2^n from n=1: 2s,4s,8s,16s,30s(cap),30s,30s,30s
    assert delays == [2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000, 30_000]
  end

  test "a stable death resets escalation to the base delay" do
    throttle = SSEBackoff.new(base_ms: 1_000, max_ms: 30_000)

    # Escalate a few rapid deaths first.
    throttle =
      Enum.reduce(1..4, throttle, fn _i, t ->
        {_d, t} = SSEBackoff.observe_death(t, false)
        t
      end)

    assert SSEBackoff.escalated?(throttle)

    # A stable death (connection lived past the stability window) resets it.
    {delay, throttle} = SSEBackoff.observe_death(throttle, true)
    assert delay == 1_000
    refute SSEBackoff.escalated?(throttle)
  end

  test "mark_stable/1 clears an escalated episode" do
    throttle =
      SSEBackoff.new()
      |> then(fn t -> elem(SSEBackoff.observe_death(t, false), 1) end)
      |> then(fn t -> elem(SSEBackoff.observe_death(t, false), 1) end)

    assert SSEBackoff.escalated?(throttle)
    assert SSEBackoff.mark_stable(throttle).consecutive == 0
  end

  test "the delay never overflows for pathologically long outages" do
    throttle = SSEBackoff.new(base_ms: 1_000, max_ms: 30_000)

    final =
      Enum.reduce(1..1_000, throttle, fn _i, t ->
        {delay, t} = SSEBackoff.observe_death(t, false)
        # Never exceeds the cap and stays a valid positive integer (no overflow).
        assert is_integer(delay) and delay > 0 and delay <= 30_000
        t
      end)

    # After the ramp it is pinned at the cap.
    assert SSEBackoff.current_delay(final) == 30_000
  end
end
