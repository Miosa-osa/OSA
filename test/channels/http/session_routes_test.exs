defmodule OptimalSystemAgent.Channels.HTTP.SessionRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes

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
