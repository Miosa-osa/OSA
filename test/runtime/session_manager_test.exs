defmodule OptimalSystemAgent.Runtime.SessionManagerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Runtime.SessionManager

  test "create_session tracks sessions without starting a loop" do
    session_id = unique_session_id()

    assert {:ok, session} =
             SessionManager.create_session(
               session_id: session_id,
               user_id: "user-1",
               channel: :http
             )

    assert session.session_id == session_id
    assert session.user_id == "user-1"
    assert session.channel == :http
    assert SessionManager.session_exists?(session_id)
    refute SessionManager.live_session?(session_id)
    assert session_id in SessionManager.tracked_session_ids()

    assert :ok = SessionManager.untrack_session(session_id)
    refute SessionManager.session_exists?(session_id)
  end

  test "track_session is idempotent" do
    session_id = unique_session_id()

    assert :ok = SessionManager.track_session(session_id, %{channel: :tui})
    assert :ok = SessionManager.track_session(session_id, %{channel: :tui})
    assert Enum.count(SessionManager.tracked_session_ids(), &(&1 == session_id)) == 1

    assert :ok = SessionManager.untrack_session(session_id)
  end

  test "lookup_loop returns :error for unknown sessions" do
    session_id = unique_session_id()

    assert :error = SessionManager.lookup_loop(session_id)
    refute SessionManager.live_session?(session_id)
  end

  defp unique_session_id do
    "session-manager-test-#{System.unique_integer([:positive, :monotonic])}"
  end
end
