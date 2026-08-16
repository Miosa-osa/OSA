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

  describe "claim/2 — terminating from outside the turn" do
    # The dedup must not become its own wedge. A turn that dies on the way IN
    # never reaches `TurnPipeline.run/3`, so it never opens a latch of its own;
    # the epoch the caller read before dispatching is what tells that case apart
    # from "the turn opened and already terminated itself".

    test "a turn that opened and terminated itself refuses the outside claim" do
      sid = session()
      observed = TurnTermination.observe(sid)

      # The turn opened and its in-turn gate (budget cap, hook block, injection
      # guard) broadcast the terminal frame.
      TurnTermination.open(sid)
      assert TurnTermination.claim(sid)

      refute TurnTermination.claim(sid, observed),
             "the route must not terminate a turn that already terminated itself"
    end

    test "a turn that never opened still terminates over an older turn's latch" do
      sid = session()

      # Turn A ran and terminated itself. Its latch is still standing, because
      # only the NEXT `open/1` would clear it.
      TurnTermination.open(sid)
      assert TurnTermination.claim(sid)

      # Turn B: the route reads the epoch, dispatches, and the Loop is gone.
      # Nothing opens a turn, so nothing in-turn can have broadcast anything.
      observed = TurnTermination.observe(sid)

      assert TurnTermination.claim(sid, observed),
             "a finished turn must always emit its terminal frame — a swallowed " <>
               "frame strands the client on keepalives forever"
    end

    test "a session that never had a turn at all can terminate" do
      sid = session()
      assert TurnTermination.claim(sid, TurnTermination.observe(sid))
    end

    test "the forced claim is still once-only" do
      sid = session()
      TurnTermination.open(sid)
      assert TurnTermination.claim(sid)

      observed = TurnTermination.observe(sid)

      winners =
        1..50
        |> Task.async_stream(fn _ -> TurnTermination.claim(sid, observed) end,
          max_concurrency: 16
        )
        |> Enum.count(fn {:ok, claimed} -> claimed end)

      assert winners == 1,
             "failing toward a duplicate is right; failing toward fifty is not"
    end

    test "an outside claim does not silence the turn that opens after it" do
      sid = session()
      observed = TurnTermination.observe(sid)
      assert TurnTermination.claim(sid, observed)

      TurnTermination.open(sid)
      assert TurnTermination.claim(sid), "the next real turn owns its own frame"
    end

    test "forget/1 drops the latch so a reused id inherits no claim" do
      sid = session()
      TurnTermination.open(sid)
      assert TurnTermination.claim(sid)
      assert TurnTermination.terminated?(sid)

      TurnTermination.forget(sid)

      refute TurnTermination.terminated?(sid)
      assert TurnTermination.observe(sid) == 0
      assert TurnTermination.claim(sid, 0), "a fresh loop under a reused id is not pre-latched"
    end
  end

  describe "observability" do
    test "a suppressed terminal frame is emitted as telemetry" do
      sid = session()
      parent = self()
      handler = "tt-suppressed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:osa, :turn_termination, :suppressed],
        fn _e, meas, meta, _ -> send(parent, {:suppressed, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      TurnTermination.open(sid)
      assert TurnTermination.claim(sid)
      refute TurnTermination.claim(sid)

      assert_receive {:suppressed, %{count: 1}, %{session_id: ^sid}}, 1_000
    end

    test "a forced claim over a stale latch is emitted as telemetry" do
      sid = session()
      parent = self()
      handler = "tt-forced-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:osa, :turn_termination, :forced],
        fn _e, meas, meta, _ -> send(parent, {:forced, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      TurnTermination.open(sid)
      assert TurnTermination.claim(sid)
      assert TurnTermination.claim(sid, TurnTermination.observe(sid))

      assert_receive {:forced, %{count: 1}, %{session_id: ^sid}}, 1_000
    end
  end
end
