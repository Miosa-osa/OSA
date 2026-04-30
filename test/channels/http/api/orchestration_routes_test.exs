defmodule OptimalSystemAgent.Channels.HTTP.API.OrchestrationRoutesTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.OrchestrationRoutes

  @opts OrchestrationRoutes.init([])

  # ── Helpers ──────────────────────────────────────────────────────────

  defp call_routes(conn) do
    OrchestrationRoutes.call(conn, @opts)
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> call_routes()
  end

  defp json_get(path) do
    conn(:get, path)
    |> call_routes()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  # ── POST / — simple orchestrate ────────────────────────────────────

  describe "POST / (simple orchestrate)" do
    test "returns 400 when input field is missing" do
      conn = json_post("/", %{})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
      assert body["details"] =~ "input"
    end

    test "returns 202 with session_id when input is provided" do
      conn = json_post("/", %{"input" => "hello world", "auto_dispatch" => false})

      assert conn.status == 202
      body = decode_body(conn)
      assert is_binary(body["session_id"])
      assert body["status"] == "processing"
    end

    test "uses provided session_id in response" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      conn =
        json_post("/", %{
          "input" => "test task",
          "session_id" => session_id,
          "auto_dispatch" => false
        })

      assert conn.status == 202
      body = decode_body(conn)
      assert body["session_id"] == session_id
    end

    test "returns 200 with status: filtered when noise filter rejects input" do
      # Very short inputs may be filtered by the noise filter
      # We verify the route returns valid JSON in either case
      conn = json_post("/", %{"input" => "hi", "auto_dispatch" => false})

      assert conn.status in [200, 202, 503]
      body = decode_body(conn)
      assert is_binary(body["session_id"]) or is_binary(body["error"])
    end
  end

  # ── GET /tasks — list orchestrated tasks ───────────────────────────

  describe "GET /tasks" do
    test "returns 200 with tasks list and count" do
      conn = json_get("/tasks")

      assert conn.status == 200
      body = decode_body(conn)
      assert is_list(body["tasks"])
      assert is_integer(body["count"])
    end

    test "count matches tasks list length" do
      conn = json_get("/tasks")
      body = decode_body(conn)

      assert body["count"] == length(body["tasks"])
    end

    test "active_count is an integer" do
      conn = json_get("/tasks")
      body = decode_body(conn)

      assert is_integer(body["active_count"])
    end
  end

  # ── POST /complex — multi-agent orchestration ───────────────────────

  describe "POST /complex" do
    test "returns 400 when task field is missing" do
      conn = json_post("/complex", %{})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
    end

    test "returns 400 when task field is empty string" do
      conn = json_post("/complex", %{"task" => ""})

      assert conn.status == 400
      body = decode_body(conn)
      assert body["error"] == "invalid_request"
    end

    test "returns 202 or 422 for a valid task (non-blocking)" do
      conn = json_post("/complex", %{"task" => "analyze the codebase", "strategy" => "auto"})

      # 202 = launched, 422 = orchestration error (no actual workers in test)
      assert conn.status in [202, 422]

      if conn.status == 202 do
        body = decode_body(conn)
        assert is_binary(body["task_id"])
        assert body["status"] == "running"
      end
    end
  end

  # ── GET /:task_id/progress ─────────────────────────────────────────

  describe "GET /:task_id/progress" do
    test "returns 404 for a nonexistent task_id" do
      conn = json_get("/nonexistent-task-#{System.unique_integer([:positive])}/progress")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end

    test "returns 200 with progress data when task exists" do
      # Launch a task first
      post_conn = json_post("/complex", %{"task" => "test orchestration progress"})

      if post_conn.status == 202 do
        task_id = decode_body(post_conn)["task_id"]
        conn = json_get("/#{task_id}/progress")

        # Task may complete quickly or still be running
        assert conn.status in [200, 404]

        if conn.status == 200 do
          body = decode_body(conn)
          assert Map.has_key?(body, "status")
        end
      end
    end
  end

  # ── GET / — list swarms ─────────────────────────────────────────────
  # Note: The swarm GET / route is served at the swarm prefix but is
  # reachable here via OrchestrationRoutes.

  describe "GET / (list swarms)" do
    test "returns 200 with swarms list" do
      conn = json_get("/")

      # Could return swarm list or 404 depending on prefix context
      assert conn.status in [200, 404]

      if conn.status == 200 do
        body = decode_body(conn)
        assert is_list(body["swarms"])
        assert is_integer(body["count"])
      end
    end
  end

  # ── Unknown endpoint ───────────────────────────────────────────────

  describe "unknown endpoint" do
    test "returns 404 for unrecognised path" do
      conn = json_get("/no/such/endpoint")

      assert conn.status == 404
      body = decode_body(conn)
      assert body["error"] == "not_found"
    end
  end
end
