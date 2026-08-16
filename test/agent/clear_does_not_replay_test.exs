defmodule OptimalSystemAgent.Agent.ClearDoesNotReplayTest do
  @moduledoc """
  What `/clear` guarantees, and the two ways it did not.

  `POST /sessions/:id/clear` is a session SWAP, not an erase — deliberately so:
  it saves the old transcript "while the loop is alive (resumable)" and records
  lineage on the new session. Its stated contract is nevertheless that the
  conversation is over: "hand back a FRESH session so the model cannot remember
  anything said before the clear."

  Saving is what broke that. `auto_save/1` rewrites `<old_id>.json`, refreshing
  its mtime to now; `SessionPersistence.list/1` — which backs
  `find_latest_for_dir/1`, the `/resume` picker and `--continue` — orders by
  mtime; and the brand-new session writes no file at all until its first turn
  completes. So in the window between the clear and the next turn, the
  DISCARDED conversation was the single most recent session for its directory,
  and the next `/continue` resumed it, with `Loop.init/1` repopulating
  `state.messages` from the file.

  The fix draws the line at ENUMERATION rather than at existence: a cleared
  session is tombstoned, so nothing finds it by "most recent" or by scanning a
  list, but `load/1` still works so `/resume <old_id>` and export keep the clear
  recoverable on purpose rather than by accident.

  Erasure is the separate operation, and it had its own hole — see the
  `SessionTranscript` describe block below.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence

  defp session, do: "clear-replay-#{System.unique_integer([:positive])}"

  defp seed(session_id, dir, text) do
    :ok = SessionPersistence.save(session_id, [%{role: "user", content: text}], dir)
    on_exit(fn -> SessionPersistence.delete(session_id) end)
    session_id
  end

  describe "a cleared session is not what the next resume lands on" do
    test "find_latest_for_dir skips the cleared session and picks the fresh one" do
      dir = "/tmp/osa-clear-#{System.unique_integer([:positive])}"
      old_id = seed(session(), dir, "the conversation the user discarded")

      assert SessionPersistence.find_latest_for_dir(dir) == old_id,
             "precondition: the pre-clear session is the most recent for this dir"

      # The clear: tombstone, then the fresh session's first save. The order is
      # what the route does — and the bug window is BEFORE that first save,
      # covered by the next test.
      :ok = SessionPersistence.mark_cleared(old_id)
      new_id = seed(session(), dir, "the fresh session")

      assert SessionPersistence.find_latest_for_dir(dir) == new_id
    end

    test "with no fresh session saved yet, resume finds nothing rather than the cleared one" do
      # This is the real window. `/clear` returns as soon as the new loop
      # starts; the new session has written no file, so before the tombstone the
      # cleared session was the only candidate and `--continue` replayed it.
      dir = "/tmp/osa-clear-#{System.unique_integer([:positive])}"
      old_id = seed(session(), dir, "secrets from before the clear")

      :ok = SessionPersistence.mark_cleared(old_id)

      refute SessionPersistence.find_latest_for_dir(dir) == old_id,
             "a cleared conversation must never be what `/continue` resumes"

      assert SessionPersistence.find_latest_for_dir(dir) == nil

      # …and this is precisely what the pre-fix `list/1` returned: the clear's
      # own save refreshed the mtime, so the discarded conversation WAS the
      # newest candidate for this directory.
      assert [%{session_id: ^old_id}] =
               SessionPersistence.list(working_dir: dir, include_cleared: true)
    end

    test "the cleared session is gone from enumeration but still loadable by id" do
      dir = "/tmp/osa-clear-#{System.unique_integer([:positive])}"
      old_id = seed(session(), dir, "still here on purpose")

      :ok = SessionPersistence.mark_cleared(old_id)

      listed = SessionPersistence.list(working_dir: dir) |> Enum.map(& &1.session_id)
      refute old_id in listed, "enumeration must not surface a cleared session"

      audit =
        SessionPersistence.list(working_dir: dir, include_cleared: true)
        |> Enum.map(& &1.session_id)

      assert old_id in audit, "an audit/recovery view must still see it"

      assert SessionPersistence.cleared?(old_id)

      # The whole point of a tombstone rather than a delete: `/resume <id>` and
      # export still work, so a clear stays undoable.
      assert {:ok, [_ | _]} = SessionPersistence.load(old_id)
    end

    test "an ordinary session is unaffected" do
      dir = "/tmp/osa-clear-#{System.unique_integer([:positive])}"
      id = seed(session(), dir, "a normal conversation")

      refute SessionPersistence.cleared?(id)
      assert SessionPersistence.find_latest_for_dir(dir) == id
      assert [%{session_id: ^id}] = SessionPersistence.list(working_dir: dir)
    end
  end

  describe "delete is the operation that actually erases" do
    # `DELETE /sessions/:id` removed the resume FILES and left every SQLite
    # transcript row, which is a second, independent copy of the conversation.
    # A "deleted" session still answered the listing, /messages, /export,
    # full-text search, and the agent's own `session_search` tool.
    alias OptimalSystemAgent.Store.SessionTranscript

    @tag :tmp_dir
    test "delete_session removes every row for that session and no others" do
      keep = session()
      drop = session()

      SessionTranscript.save_turn(drop, "user", "the sentence that must go away")
      SessionTranscript.save_turn(drop, "assistant", "acknowledged")
      SessionTranscript.save_turn(keep, "user", "an unrelated conversation")

      on_exit(fn -> SessionTranscript.delete_session(keep) end)

      assert {:ok, 2} = SessionTranscript.delete_session(drop)

      assert SessionTranscript.get_transcript(drop) == []
      assert length(SessionTranscript.get_transcript(keep)) == 1
    end

    test "erasing a session that has no rows is a no-op, not an error" do
      assert {:ok, 0} = SessionTranscript.delete_session(session())
    end
  end
end
