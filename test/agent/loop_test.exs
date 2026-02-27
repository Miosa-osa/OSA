defmodule OptimalSystemAgent.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_session_id do
    "smoke-loop-#{:erlang.unique_integer([:positive])}"
  end

  # ---------------------------------------------------------------------------
  # Module smoke tests
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "Loop module is defined and loaded" do
      assert Code.ensure_loaded?(Loop)
    end

    test "exports start_link/1" do
      assert function_exported?(Loop, :start_link, 1)
    end

    test "exports process_message/2" do
      assert function_exported?(Loop, :process_message, 2)
    end

    test "exports get_owner/1" do
      assert function_exported?(Loop, :get_owner, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # start_link smoke tests
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    test "starts a GenServer process for a new session" do
      session_id = unique_session_id()

      pid =
        start_supervised!(
          {Loop, [session_id: session_id, channel: :cli]},
          id: String.to_atom(session_id)
        )

      assert Process.alive?(pid)
    end

    test "registers the session in SessionRegistry" do
      session_id = unique_session_id()

      start_supervised!(
        {Loop, [session_id: session_id, channel: :cli]},
        id: String.to_atom(session_id)
      )

      assert [{_pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_owner/1 smoke test
  # ---------------------------------------------------------------------------

  describe "get_owner/1" do
    test "returns nil for a session that does not exist" do
      assert Loop.get_owner("nonexistent-session-#{:erlang.unique_integer([:positive])}") == nil
    end

    test "returns the user_id stored at session start" do
      session_id = unique_session_id()
      user_id = "user-#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Loop, [session_id: session_id, user_id: user_id, channel: :cli]},
        id: String.to_atom(session_id)
      )

      assert Loop.get_owner(session_id) == user_id
    end
  end
end
