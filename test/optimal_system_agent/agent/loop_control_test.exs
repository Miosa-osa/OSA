defmodule OptimalSystemAgent.Agent.LoopControlTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.LoopControl
  alias OptimalSystemAgent.Agent.SessionPersistence

  test "parses bounded operator intervals" do
    assert {:ok, 5_000} = LoopControl.parse_interval("5s")
    assert {:ok, 300_000} = LoopControl.parse_interval("5m")
    assert {:ok, 7_200_000} = LoopControl.parse_interval("2h")
    assert {:error, :invalid_interval} = LoopControl.parse_interval("1s")
    assert {:error, :invalid_interval} = LoopControl.parse_interval("soon")
  end

  test "start, status, and stop expose explicit operator control" do
    session_id = "loop-control-#{System.unique_integer([:positive])}"
    on_exit(fn -> LoopControl.stop(session_id) end)

    assert {:ok, %{"prompt" => "check the deployment"}} =
             LoopControl.start(session_id, 5_000, "check the deployment")

    assert %{"interval_ms" => 5_000, "tick_count" => 0} = LoopControl.status(session_id)
    assert :ok = LoopControl.stop(session_id)
    assert LoopControl.status(session_id) == nil
  end

  test "a tick is not counted when no live session queue accepts it" do
    session_id = "missing-loop-#{System.unique_integer([:positive])}"

    entry = %{
      interval_ms: 60_000,
      prompt: "check",
      tick_count: 0,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      last_tick_at: nil,
      timer_ref: nil
    }

    assert {:noreply, %{^session_id => updated}} =
             LoopControl.handle_info({:tick, session_id}, %{session_id => entry})

    assert updated.tick_count == 0
    assert updated.last_tick_at == nil
    Process.cancel_timer(updated.timer_ref)
  end

  test "restart does not rearm an ambiguously dispatched tick" do
    session_id = "dispatching-loop-#{System.unique_integer([:positive])}"

    stored = %{
      "interval_ms" => 60_000,
      "prompt" => "check once",
      "tick_count" => 1,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "last_tick_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "last_tick_status" => "dispatching"
    }

    assert :ok = SessionPersistence.save_inbox(session_id, :operator_loop, [stored])
    on_exit(fn -> SessionPersistence.save_inbox(session_id, :operator_loop, []) end)

    assert {:ok, restored} = LoopControl.init(%{})
    assert %{timer_ref: nil, last_tick_status: "dispatching"} = restored[session_id]
  end
end
