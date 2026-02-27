defmodule OptimalSystemAgent.Channels.HTTP.FleetAPITest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API

  @opts API.init([])

  # ── Helpers ──────────────────────────────────────────────────────────

  setup_all do
    # Ensure Fleet subsystem is running (AgentRegistry + SentinelPool + Registry).
    # Use the supervisor so the tree is properly managed and doesn't propagate exits.
    unless Process.whereis(OptimalSystemAgent.Fleet.Supervisor) do
      {:ok, _} = OptimalSystemAgent.Fleet.Supervisor.start_link([])
    end

    :ok
  end

  setup do
    # Trap exits so sentinel start failures don't kill the test process
    Process.flag(:trap_exit, true)

    # Disable auth so we can hit routes without JWT
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    Application.put_env(:optimal_system_agent, :require_auth, false)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)
    end)

    :ok
  end

  defp call_api(conn) do
    API.call(conn, @opts)
  end

  defp json_post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> call_api()
  end

  defp json_get(path) do
    conn(:get, path)
    |> call_api()
  end

  defp decode_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  # ── POST /fleet/register ──────────────────────────────────────────

  describe "POST /fleet/register" do
    test "returns 201 on successful registration" do
      agent_id = "edge-agent-#{System.unique_integer([:positive])}"
      conn = json_post("/fleet/register", %{agent_id: agent_id, capabilities: ["compute"]})

      assert conn.status == 201
      body = decode_body(conn)
      assert body["status"] == "registered"
      assert body["agent_id"] == agent_id
      assert body["capabilities"] == ["compute"]
    end

    test "returns 409 when agent already registered" do
      agent_id = "edge-dup-#{System.unique_integer([:positive])}"
      conn1 = json_post("/fleet/register", %{agent_id: agent_id})
      assert conn1.status == 201

      conn2 = json_post("/fleet/register", %{agent_id: agent_id})
      assert conn2.status == 409
      assert decode_body(conn2)["error"] == "conflict"
    end

    test "returns 400 when agent_id is missing" do
      conn = json_post("/fleet/register", %{capabilities: ["gpu"]})

      assert conn.status == 400
      assert decode_body(conn)["error"] == "invalid_request"
    end
  end

  # ── GET /fleet/:agent_id/instructions ──────────────────────────────

  describe "GET /fleet/:agent_id/instructions" do
    test "returns 204 when no pending tasks" do
      agent_id = "poll-agent-#{System.unique_integer([:positive])}"
      # Register first so the agent exists
      json_post("/fleet/register", %{agent_id: agent_id})

      conn = json_get("/fleet/#{agent_id}/instructions")

      assert conn.status == 204
    end

    test "returns 200 with OSCP CloudEvent when task is pending" do
      agent_id = "poll-task-#{System.unique_integer([:positive])}"
      task_id = "task-#{System.unique_integer([:positive])}"

      # Register the agent
      json_post("/fleet/register", %{agent_id: agent_id})

      # Enqueue a task for this agent
      OptimalSystemAgent.Agent.TaskQueue.enqueue_sync(
        task_id,
        agent_id,
        %{instruction: "run diagnostics"}
      )

      conn = json_get("/fleet/#{agent_id}/instructions")

      assert conn.status == 200

      # Verify CloudEvents content type
      content_type =
        Enum.find_value(conn.resp_headers, fn
          {"content-type", v} -> v
          _ -> nil
        end)

      assert content_type =~ "application/cloudevents+json"

      body = decode_body(conn)
      assert body["type"] == "oscp.instruction"
      assert body["data"]["agent_id"] == agent_id
      assert body["data"]["task_id"] == task_id
    end

    test "second poll returns 204 after task is leased" do
      agent_id = "poll-lease-#{System.unique_integer([:positive])}"
      task_id = "task-lease-#{System.unique_integer([:positive])}"

      json_post("/fleet/register", %{agent_id: agent_id})

      OptimalSystemAgent.Agent.TaskQueue.enqueue_sync(
        task_id,
        agent_id,
        %{instruction: "check status"}
      )

      # First poll leases the task
      conn1 = json_get("/fleet/#{agent_id}/instructions")
      assert conn1.status == 200

      # Second poll — no more pending tasks
      conn2 = json_get("/fleet/#{agent_id}/instructions")
      assert conn2.status == 204
    end
  end
end
