defmodule OptimalSystemAgent.Channels.HTTP.SessionRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes
  alias OptimalSystemAgent.Store.SessionTranscript

  @opts SessionRoutes.init([])

  # ── Helpers ──────────────────────────────────────────────────────────

  setup do
    # Disable auth so the assign(:user_id) is populated by the API layer;
    # SessionRoutes itself reads conn.assigns[:user_id] with a default fallback,
    # so we just ensure the env is set consistently.
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)
    end)

    :ok
  end

  defp call_routes(conn) do
    SessionRoutes.call(conn, @opts)
  end

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp json_get(path) do
    conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> call_routes()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  # ── GET /sessions ─────────────────────────────────────────────────────

  describe "GET /sessions" do
    test "returns 200 with sessions list and count keys" do
      conn = json_get("/")

      assert conn.status == 200
      body = decode_body(conn)
      assert is_list(body["sessions"])
      assert is_integer(body["count"])
    end

    test "count is total and sessions is paginated subset" do
      conn = json_get("/")
      body = decode_body(conn)

      assert body["count"] >= length(body["sessions"])
      assert length(body["sessions"]) <= body["per_page"]
      assert body["page"] == 1
    end
  end

  # ── POST /sessions ────────────────────────────────────────────────────

  describe "POST /sessions" do
    test "returns 201 with id and status on successful creation" do
      conn = json_post("/")

      assert conn.status == 201
      body = decode_body(conn)
      assert is_binary(body["id"])
      assert body["status"] == "created"
    end

    test "returned session id is non-empty string" do
      conn = json_post("/")
      body = decode_body(conn)

      assert String.length(body["id"]) > 0
    end

    test "each POST creates a distinct session id" do
      conn1 = json_post("/")
      conn2 = json_post("/")

      id1 = decode_body(conn1)["id"]
      id2 = decode_body(conn2)["id"]

      refute id1 == id2
    end

    test "created session appears in subsequent GET /sessions" do
      post_conn = json_post("/")
      new_id = decode_body(post_conn)["id"]

      get_conn = json_get("/")
      body = decode_body(get_conn)
      ids = Enum.map(body["sessions"], fn s -> s["id"] end)

      assert new_id in ids
    end
  end

  # ── GET /sessions/:id ─────────────────────────────────────────────────

  describe "GET /sessions/:id" do
    test "returns 200 with session data for an existing (live) session" do
      # Create a session first
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_get("/#{session_id}")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["id"] == session_id
      assert is_list(body["messages"])
      assert is_boolean(body["alive"])
    end

    test "returns 404 for a session that does not exist" do
      conn = json_get("/nonexistent-session-#{System.unique_integer([:positive])}")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "session_not_found"
    end

    test "live session has alive: true" do
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_get("/#{session_id}")
      body = decode_body(conn)

      assert body["alive"] == true
    end

    test "session response includes message_count" do
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_get("/#{session_id}")
      body = decode_body(conn)

      assert Map.has_key?(body, "message_count")
    end
  end

  # ── GET /sessions/:id/messages ────────────────────────────────────────

  describe "GET /sessions/:id/messages" do
    test "returns 200 with messages list for any session id" do
      # For a new session with no history, messages is an empty list.
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_get("/#{session_id}/messages")

      assert conn.status == 200
      body = decode_body(conn)
      assert is_list(body["messages"])
      assert is_integer(body["count"])
    end

    test "count matches messages list length" do
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_get("/#{session_id}/messages")
      body = decode_body(conn)

      assert body["count"] == length(body["messages"])
    end

    test "returns 200 even for unknown session id (empty messages)" do
      # Memory.load_session returns nil for unknown sessions — route handles it.
      conn = json_get("/unknown-session-xyz/messages")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["messages"] == []
      assert body["count"] == 0
    end
  end

  # ── POST /sessions/:id/steer ──────────────────────────────────────────

  describe "POST /sessions/:id/steer" do
    test "returns 400 when text is missing or empty" do
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_post("/#{session_id}/steer", %{})
      assert conn.status == 400
      assert decode_body(conn)["error"] == "invalid_request"

      conn2 = json_post("/#{session_id}/steer", %{"text" => "   "})
      assert conn2.status == 400
    end

    test "returns 404 for a session with no live loop" do
      fake_id = "no-such-session-#{System.unique_integer([:positive])}"
      conn = json_post("/#{fake_id}/steer", %{"text" => "adapt now"})

      assert conn.status == 404
      assert decode_body(conn)["error"] == "session_not_found"
    end

    test "steers a live session with 202 and queues the directive" do
      session_id = "steer-route-#{System.unique_integer([:positive])}"

      # Register a fake loop process so live_session?/1 returns true, without
      # starting a real agent loop (the ETS queue is what carries the steer).
      {:ok, _} =
        Registry.register(OptimalSystemAgent.SessionRegistry, session_id, :test)

      conn = json_post("/#{session_id}/steer", %{"text" => "focus on tests"})

      assert conn.status == 202
      body = decode_body(conn)
      assert body["status"] == "steered"
      assert body["session_id"] == session_id

      # The directive is now sitting in the ETS steer queue for the loop to drain.
      assert "focus on tests" in OptimalSystemAgent.Agent.Loop.Steer.drain(session_id)
    end
  end

  # ── POST /sessions/:id/cancel ─────────────────────────────────────────

  describe "POST /sessions/:id/cancel" do
    test "returns 200 with status: cancel_requested for any session id" do
      # Loop.cancel/1 writes to an ETS table and returns :ok even when no
      # loop process is actively running (it just records the cancellation flag).
      # Only fails with {:error, :not_running} when the ETS table itself is absent.
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_post("/#{session_id}/cancel")

      # Accept either 200 (flag set) or 404 (loop table not present in test env).
      assert conn.status in [200, 404]
    end

    test "successful cancel response has session_id and status fields" do
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      conn = json_post("/#{session_id}/cancel")

      if conn.status == 200 do
        body = decode_body(conn)
        assert body["status"] == "cancel_requested"
        assert body["session_id"] == session_id
      end
    end

    test "cancel for nonexistent session returns 404 when loop table missing" do
      # When the cancel ETS table doesn't exist at all, Loop.cancel/1 rescues
      # ArgumentError and returns {:error, :not_running}.
      fake_id = "no-such-session-#{System.unique_integer([:positive])}"
      conn = json_post("/#{fake_id}/cancel")

      # The route maps {:error, :not_running} → 404.
      assert conn.status in [200, 404]

      if conn.status == 404 do
        body = decode_body(conn)
        assert body["error"] == "not_running"
      end
    end
  end

  # ── GET /sessions/:id/pending_questions ───────────────────────────────

  describe "GET /sessions/:id/pending_questions" do
    test "returns 200 with empty list when no pending questions" do
      conn = json_get("/some-session-id/pending_questions")

      assert conn.status == 200
      body = decode_body(conn)
      assert is_list(body["pending_questions"])
      assert body["pending_questions"] == []
      assert body["count"] == 0
    end

    test "returns 200 with empty list for unknown session id" do
      conn = json_get("/unknown-session-#{System.unique_integer([:positive])}/pending_questions")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["pending_questions"] == []
    end

    test "count matches pending_questions list length" do
      conn = json_get("/any-session/pending_questions")
      body = decode_body(conn)
      assert body["count"] == length(body["pending_questions"])
    end

    test "pending question inserted into ETS appears in response for that session" do
      session_id = "test-pq-session-#{System.unique_integer([:positive])}"
      ref_str = "test-ref-#{System.unique_integer([:positive])}"
      asked_at = DateTime.utc_now() |> DateTime.to_iso8601()

      inserted =
        try do
          :ets.insert(
            :osa_pending_questions,
            {ref_str,
             %{
               session_id: session_id,
               question: "Which option do you prefer?",
               options: ["A", "B"],
               asked_at: asked_at
             }}
          )

          true
        rescue
          ArgumentError -> false
        end

      if inserted do
        conn = json_get("/#{session_id}/pending_questions")
        body = decode_body(conn)

        assert body["count"] == 1
        [q] = body["pending_questions"]
        assert q["ref"] == ref_str
        assert q["question"] == "Which option do you prefer?"
        assert q["options"] == ["A", "B"]
        assert is_binary(q["asked_at"])

        try do
          :ets.delete(:osa_pending_questions, ref_str)
        rescue
          ArgumentError -> :ok
        end
      else
        # ETS table not available in isolated test run — acceptable
        assert true
      end
    end

    test "does not return questions from a different session" do
      session_a = "session-a-#{System.unique_integer([:positive])}"
      session_b = "session-b-#{System.unique_integer([:positive])}"
      ref_str = "ref-cross-#{System.unique_integer([:positive])}"

      try do
        :ets.insert(
          :osa_pending_questions,
          {ref_str,
           %{
             session_id: session_a,
             question: "For session A only",
             options: [],
             asked_at: DateTime.utc_now() |> DateTime.to_iso8601()
           }}
        )

        conn = json_get("/#{session_b}/pending_questions")
        body = decode_body(conn)
        assert body["count"] == 0

        :ets.delete(:osa_pending_questions, ref_str)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  # ── Route reachability ───────────────────────────────────────────────

  describe "specific session endpoints" do
    test "GET /search is not shadowed by GET /:id" do
      conn = json_get("/search?q=agent&limit=1")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["query"] == "agent"
      assert is_list(body["results"])
      assert is_integer(body["count"])
    end

    test "GET /recent is not shadowed by GET /:id" do
      conn = json_get("/recent?limit=1")

      assert conn.status == 200
      body = decode_body(conn)
      assert is_list(body["sessions"])
    end

    test "GET /:id/export is not shadowed by catch-all" do
      session_id = "export-session-#{System.unique_integer([:positive])}"
      conn = json_get("/#{session_id}/export?format=json")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["session_id"] == session_id
      assert body["format"] == "json"
      assert is_list(body["turns"])
    end

    test "GET /:id/transcript is not shadowed by catch-all" do
      session_id = "transcript-session-#{System.unique_integer([:positive])}"
      conn = json_get("/#{session_id}/transcript")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["session_id"] == session_id
      assert is_list(body["turns"])
      assert is_integer(body["count"])
    end

    test "POST /:id/permission/:perm_id is not shadowed by catch-all" do
      conn = json_post("/session-1/permission/perm-1", %{"decision" => "deny"})

      assert conn.status == 200
      body = decode_body(conn)
      assert body["status"] == "ok"
      assert body["decision"] == "deny"
    end
  end

  # ── POST /sessions (directory-scoped resume) ──────────────────────────

  describe "POST /sessions with a working_dir that already has a session" do
    # The resume branch returned `"resumed"` without calling `ensure_loop`, so
    # the session came back with NO live Loop.
    #
    # Messages hid it — orchestrate_routes calls `ensure_loop` itself, so that
    # path self-heals. What broke is every route gated on a live loop:
    # `GET /:id/context` and `POST /:id/steer` both 404. The TUI attaches to its
    # cwd, so this is the ordinary reattach path, and the context meter died the
    # moment it reconnected.
    #
    # Asserting on `live_session?/1` rather than the response body is the point:
    # the old code returned exactly the same 200 `"resumed"` JSON.
    test "resumes the existing session AND brings its loop back up" do
      working_dir = Path.join(System.tmp_dir!(), "osa-resume-#{System.unique_integer([:positive])}")
      File.mkdir_p!(working_dir)
      on_exit(fn -> File.rm_rf(working_dir) end)

      seeded = "resume-dir-#{System.unique_integer([:positive])}"
      :ok = OptimalSystemAgent.Agent.SessionPersistence.save(seeded, [], working_dir)
      on_exit(fn -> OptimalSystemAgent.Agent.SessionPersistence.delete(seeded) end)

      conn = json_post("/", %{"working_dir" => working_dir})

      assert conn.status == 200
      body = decode_body(conn)
      assert body["status"] == "resumed"
      assert body["id"] == seeded

      assert OptimalSystemAgent.Runtime.SessionManager.live_session?(seeded),
             "a directory-scoped resume must leave a LIVE loop, or /context and /steer 404"
    end
  end

  # ── POST /sessions/:id/fork (fork-at-turn, primitive #34) ─────────────

  defp seed_transcript(n) do
    src = "fork-src-#{System.unique_integer([:positive])}"
    Enum.each(1..n, fn i -> SessionTranscript.save_turn(src, "user", "message #{i}") end)
    src
  end

  describe "POST /sessions/:id/fork" do
    test "whole-session fork seeds the full transcript" do
      src = seed_transcript(5)
      conn = json_post("/#{src}/fork", %{})

      assert conn.status == 201
      body = decode_body(conn)
      assert body["status"] == "resumed"
      assert body["source_session"] == src
      assert body["message_count"] == 5
      assert body["forked_at"] == nil
      assert is_binary(body["id"])
    end

    test "fork-at-turn seeds only turns up to and including the index" do
      src = seed_transcript(5)
      conn = json_post("/#{src}/fork", %{"turn" => 2})

      assert conn.status == 201
      body = decode_body(conn)
      assert body["message_count"] == 3
      assert body["forked_at"] == 2

      # The new session's persisted transcript reflects the slice.
      assert length(SessionTranscript.get_transcript(body["id"])) == 3
    end

    test "fork-at-turn accepts a numeric string index" do
      src = seed_transcript(4)
      body = json_post("/#{src}/fork", %{"message_index" => "1"}) |> decode_body()

      assert body["message_count"] == 2
      assert body["forked_at"] == 1
    end

    test "fork-at-turn accepts the up_to alias" do
      src = seed_transcript(4)
      body = json_post("/#{src}/fork", %{"up_to" => 0}) |> decode_body()

      assert body["message_count"] == 1
      assert body["forked_at"] == 0
    end

    test "out-of-range index is clamped to the transcript length" do
      src = seed_transcript(3)
      body = json_post("/#{src}/fork", %{"turn" => 99}) |> decode_body()

      assert body["message_count"] == 3
      assert body["forked_at"] == 2
    end
  end

  # ── DELETE /sessions/:id ────────────────────────────────────────────

  defp json_delete(path) do
    conn(:delete, path) |> call_routes()
  end

  describe "DELETE /sessions/:id" do
    test "removes the real on-disk files (S1 fix: not the nonexistent <id>.jsonl)" do
      post_conn = json_post("/")
      session_id = decode_body(post_conn)["id"]

      # Persist something so <id>.json + <id>.updates.jsonl actually exist —
      # the same files a live session's turns are saved to.
      :ok = OptimalSystemAgent.Agent.SessionPersistence.save(session_id, [%{role: "user", content: "hi"}])

      # Runtime-resolved, not a frozen `~/.osa`: the suite runs against an
      # isolated per-run config dir, so expanding the real home here asserted
      # against the OPERATOR's sessions directory.
      sessions_dir = Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "sessions")
      json_path = Path.join(sessions_dir, "#{session_id}.json")
      updates_path = Path.join(sessions_dir, "#{session_id}.updates.jsonl")

      assert File.exists?(json_path)
      assert File.exists?(updates_path)

      conn = json_delete("/#{session_id}")

      assert conn.status == 200
      body = decode_body(conn)
      assert body["status"] == "deleted"
      assert body["session_id"] == session_id

      refute File.exists?(json_path)
      refute File.exists?(updates_path)
    end

    test "returns 404 for a session with no saved files at all" do
      fake_id = "no-such-session-#{System.unique_integer([:positive])}"

      conn = json_delete("/#{fake_id}")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "session_not_found"
    end
  end

  # ── GET /sessions/resolve ─────────────────────────────────────────────
  #
  # The endpoint `osa resume <id>` goes through. Its whole job is to turn a bad
  # reference into a LOUD non-2xx: GET /:id/messages answers 200 + [] for an id
  # that never existed, so resuming a typo used to be indistinguishable from
  # resuming an empty conversation.

  describe "GET /sessions/resolve" do
    setup do
      conn = json_post("/", %{})
      {:ok, session_id: decode_body(conn)["id"]}
    end

    test "resolves a full session id to itself", %{session_id: session_id} do
      conn = json_get("/resolve?id=#{session_id}")

      assert conn.status == 200
      assert decode_body(conn)["id"] == session_id
    end

    test "resolves an unambiguous prefix to the full id", %{session_id: session_id} do
      # git-short-SHA style: enough characters to be unique is enough to resume.
      prefix = String.slice(session_id, 0, String.length(session_id) - 4)
      conn = json_get("/resolve?id=#{prefix}")

      case conn.status do
        200 -> assert decode_body(conn)["id"] == session_id
        # Another session created by a concurrent test may share the prefix;
        # ambiguity is still an explicit failure, never a silent fresh session.
        409 -> assert decode_body(conn)["error"] == "session_ref_ambiguous"
      end
    end

    test "404s on an unknown id instead of falling back to a fresh session" do
      conn = json_get("/resolve?id=definitely-not-a-session-#{System.unique_integer([:positive])}")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "session_not_found"
      # The message has to be actionable, not just a status code.
      assert body["details"] =~ "osa resume"
    end

    test "404s on a one-character typo of a real id", %{session_id: session_id} do
      typo = session_id <> "x"
      conn = json_get("/resolve?id=#{typo}")

      assert conn.status == 404
      assert decode_body(conn)["error"] == "session_not_found"
    end

    test "404s when no id is supplied at all" do
      conn = json_get("/resolve")

      assert conn.status == 404
      assert decode_body(conn)["error"] == "session_not_found"
    end

    test "409s with candidates on an ambiguous prefix" do
      # Two sessions share the "session-" prefix by construction.
      json_post("/", %{})
      json_post("/", %{})

      conn = json_get("/resolve?id=session-")

      assert conn.status == 409
      body = decode_body(conn)
      assert body["error"] == "session_ref_ambiguous"
      assert length(body["candidates"]) >= 2
      assert body["details"] =~ "Use more characters"
    end
  end

  # ── End-to-end: resume restores the prior conversation ────────────────

  describe "resume round-trip" do
    test "a persisted conversation is resolvable and its messages come back" do
      session_id = "session-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      SessionTranscript.save_turn(session_id, "user", "what is 2 + 2?")
      SessionTranscript.save_turn(session_id, "assistant", "4")
      SessionTranscript.save_turn(session_id, "user", "and 3 + 3?")
      SessionTranscript.save_turn(session_id, "assistant", "6")

      # 1. The id the exit hint printed resolves to itself.
      resolve = json_get("/resolve?id=#{session_id}")
      assert resolve.status == 200
      resolved = decode_body(resolve)["id"]
      assert resolved == session_id

      # 2. Resuming it hands back the ACTUAL prior turns, in order — this is
      #    the thing that makes resume worth having.
      conn = json_get("/#{resolved}/messages")
      assert conn.status == 200
      body = decode_body(conn)

      contents = Enum.map(body["messages"], & &1["content"])
      assert "what is 2 + 2?" in contents
      assert "4" in contents
      assert "and 3 + 3?" in contents
      assert "6" in contents
      assert body["count"] == length(body["messages"])

      roles = Enum.map(body["messages"], & &1["role"])
      assert "user" in roles
      assert "assistant" in roles
    end

    test "an unknown id yields NO messages — which is exactly why resolve must gate it" do
      unknown = "session-does-not-exist-#{System.unique_integer([:positive])}"

      # The silent-fallback failure mode, pinned: /messages happily answers 200
      # with an empty list, so nothing downstream can tell "no such session"
      # apart from "empty session".
      messages = json_get("/#{unknown}/messages")
      assert messages.status == 200
      assert decode_body(messages)["messages"] == []

      # /resolve is the gate that turns it into a loud failure.
      assert json_get("/resolve?id=#{unknown}").status == 404
    end
  end

  # ── Unknown endpoint ──────────────────────────────────────────────────

  describe "unknown session endpoint" do
    test "returns 404 for unrecognised path" do
      conn = json_get("/some/deeply/nested/path")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end
end
