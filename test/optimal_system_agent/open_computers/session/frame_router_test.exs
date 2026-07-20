defmodule OptimalSystemAgent.OpenComputers.Session.FrameRouterTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.FrameRouter

  @initial_state %{phase: :hello, grant_token: nil}

  describe "handle/2 — hello_ok" do
    test "returns start_heartbeat action with default 30s when not specified" do
      {actions, _state} = FrameRouter.handle({:hello_ok, %{}}, @initial_state)
      assert {:start_heartbeat, 30_000} in actions
    end

    test "returns start_heartbeat with custom heartbeat_ms from info" do
      {actions, _state} = FrameRouter.handle({:hello_ok, %{heartbeat_ms: 15_000}}, @initial_state)
      assert {:start_heartbeat, 15_000} in actions
    end

    test "sets phase to :active in returned state" do
      {_actions, state} = FrameRouter.handle({:hello_ok, %{}}, @initial_state)
      assert state.phase == :active
    end
  end

  describe "handle/2 — ping" do
    test "returns send pong with same sequence number" do
      {actions, _state} = FrameRouter.handle({:ping, 42}, @initial_state)
      assert {:send, {:pong, 42}} in actions
    end

    test "does not modify state" do
      {_actions, state} = FrameRouter.handle({:ping, 1}, @initial_state)
      assert state == @initial_state
    end
  end

  describe "handle/2 — close" do
    test "returns :reconnect action" do
      {actions, _state} = FrameRouter.handle({:close, 1000, "normal"}, @initial_state)
      assert :reconnect in actions
    end
  end

  describe "handle/2 — grant_renewed" do
    test "updates grant_token in state" do
      info = %{new_token: "new_jwt", old_jti: "old-jti", new_jti: "new-jti"}
      {_actions, state} = FrameRouter.handle({:grant_renewed, info}, @initial_state)
      assert state.grant_token == "new_jwt"
    end

    test "returns empty actions list" do
      info = %{new_token: "tok"}
      {actions, _state} = FrameRouter.handle({:grant_renewed, info}, @initial_state)
      assert actions == []
    end
  end

  describe "handle/2 — job" do
    test "returns a list of actions for an exec_on_host job" do
      # The Executor.Supervisor may already be running (started by the app supervisor).
      # We just need it to be up; tolerate :already_started.
      _sup_result =
        case start_supervised(
               {OptimalSystemAgent.OpenComputers.Executor.Supervisor, []},
               id: :exec_sup_frame_router_test
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      job = %{id: "job-1", kind: :exec_on_host, cmd: "echo hi"}
      {actions, _state} = FrameRouter.handle({:job, job}, @initial_state)
      assert is_list(actions)
    end
  end

  describe "handle/2 — unknown frame" do
    test "returns empty actions for unknown frames" do
      {actions, _state} = FrameRouter.handle({:unknown_frame, "data"}, @initial_state)
      assert actions == []
    end

    test "does not modify state for unknown frames" do
      {_actions, state} = FrameRouter.handle({:unknown_frame, "data"}, @initial_state)
      assert state == @initial_state
    end
  end
end
