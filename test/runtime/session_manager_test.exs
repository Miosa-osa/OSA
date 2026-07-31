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

  describe "swap_provider/3" do
    test "materialises the loop instead of 404ing when the session has not started one" do
      # Session Loops start lazily on the first message, but users switch models
      # BEFORE sending anything (open OSA → pick a model → talk). This path used to
      # only LOOK UP a loop, so a pre-first-turn switch returned {:error, :not_found}
      # → HTTP 404 session_not_found → a "switch failed" toast every time.
      session_id = unique_session_id()
      refute SessionManager.live_session?(session_id)

      result = SessionManager.swap_provider(session_id, "ollama", "glm-5.2:cloud")

      refute match?({:error, :not_found}, result),
             "a model switch must not 404 just because the session's loop hasn't started yet"

      assert SessionManager.live_session?(session_id),
             "swap_provider must materialise the loop the first turn will use"

      SessionManager.untrack_session(session_id)
    end
  end

  defp unique_session_id do
    "session-manager-test-#{System.unique_integer([:positive, :monotonic])}"
  end
end
