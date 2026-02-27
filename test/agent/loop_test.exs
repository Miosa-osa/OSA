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

    # __info__/1 is more reliable than function_exported?/3 for functions
    # defined via GenServer macros (defoverridable + def).
    test "exports start_link" do
      funs = Loop.__info__(:functions)
      assert Enum.any?(funs, fn {name, _arity} -> name == :start_link end)
    end

    test "exports process_message" do
      funs = Loop.__info__(:functions)
      assert {:process_message, 2} in funs
    end

    test "exports get_owner" do
      funs = Loop.__info__(:functions)
      assert {:get_owner, 1} in funs
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
