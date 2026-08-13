defmodule OptimalSystemAgent.Agent.TurnTerminationTest do
  @moduledoc """
  `POST /api/v1/orchestrate` terminated one turn twice: TurnPipeline broadcasts
  a terminal frame before returning `{:error, reason}` for the turn/budget limit
  gate and for a UserPromptSubmit hook block, and the route's async task then
  ran its own `emit_terminal_error/2` for that same error.

  Under the TUI's queue gate the duplicate `done` is not cosmetic — it drains
  the queue, the drained message opens a new turn, and the second `done` then
  lands inside it. That is the early-drain bug the gate exists to prevent.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TurnTermination

  defp session, do: "turn-term-#{System.unique_integer([:positive])}"

  test "the first claimant sends and the second is refused" do
    sid = session()
    TurnTermination.open(sid)

    assert TurnTermination.claim(sid), "the pipeline's terminal frame must go out"
    refute TurnTermination.claim(sid), "the route must not terminate the same turn again"
    refute TurnTermination.claim(sid)
  end

  test "the latch is per turn, not per session" do
    sid = session()

    TurnTermination.open(sid)
    assert TurnTermination.claim(sid)

    # Without `open/1` the first turn would silence every turn after it.
    TurnTermination.open(sid)
    assert TurnTermination.claim(sid), "a new turn must be able to terminate itself"
  end

  test "sessions do not latch each other" do
    a = session()
    b = session()
    TurnTermination.open(a)
    TurnTermination.open(b)

    assert TurnTermination.claim(a)
    assert TurnTermination.claim(b), "one session's terminal frame must not silence another's"
  end

  test "a crash before any turn opened can still terminate" do
    # The route's fallback exists precisely for the case where nothing
    # broadcast anything. An unopened session must not be pre-latched, or the
    # SSE loop spins on keepalives forever.
    assert TurnTermination.claim(session())
  end

  test "concurrent terminations of one turn resolve to exactly one winner" do
    sid = session()
    TurnTermination.open(sid)

    winners =
      1..50
      |> Task.async_stream(fn _ -> TurnTermination.claim(sid) end, max_concurrency: 16)
      |> Enum.count(fn {:ok, claimed} -> claimed end)

    assert winners == 1, "a check-then-send race would let more than one frame out"
  end

  test "terminated? reports the latch state" do
    sid = session()
    TurnTermination.open(sid)
    refute TurnTermination.terminated?(sid)
    assert TurnTermination.claim(sid)
    assert TurnTermination.terminated?(sid)
  end
end
