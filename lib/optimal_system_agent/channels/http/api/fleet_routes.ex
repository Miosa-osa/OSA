defmodule OptimalSystemAgent.Channels.HTTP.API.FleetRoutes do
  @moduledoc """
  Fleet management routes.

    POST /register
    GET  /:agent_id/instructions
    POST /heartbeat
    GET  /agents
    GET  /:agent_id
    POST /dispatch
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Fleet.Registry, as: Fleet
  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Protocol.OSCP

  plug(:match)
  plug(:dispatch)

  # ── POST /heartbeat ────────────────────────────────────────────────

  post "/heartbeat" do
    with %{"agent_id" => agent_id} <- conn.body_params do
      metrics = Map.drop(conn.body_params, ["agent_id"])

      try do
        Fleet.heartbeat(agent_id, metrics)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "ok"}))
      catch
        :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: agent_id")
    end
  end

  # ── GET /agents ────────────────────────────────────────────────────

  get "/agents" do
    try do
      agents = Fleet.list_agents()

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{agents: agents, count: length(agents)}))
    catch
      :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
    end
  end

  # ── POST /register ─────────────────────────────────────────────────

  post "/register" do
    with %{"agent_id" => agent_id} when is_binary(agent_id) and agent_id != "" <-
           conn.body_params do
      capabilities = conn.body_params["capabilities"] || []

      try do
        case Fleet.register_agent(agent_id, capabilities) do
          {:ok, _pid} ->
            body =
              Jason.encode!(%{
                status: "registered",
                agent_id: agent_id,
                capabilities: capabilities
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, body)

          {:error, :already_registered} ->
            json_error(conn, 409, "conflict", "Agent #{agent_id} is already registered")

          {:error, reason} ->
            json_error(conn, 500, "registration_error", inspect(reason))
        end
      catch
        :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: agent_id")
    end
  end

  # ── GET /:agent_id/instructions ────────────────────────────────────
  # Must be defined before GET /:agent_id to avoid routing ambiguity.

  get "/:agent_id/instructions" do
    agent_id = conn.params["agent_id"]

    try do
      case Tasks.lease(agent_id) do
        {:ok, task} ->
          event =
            OSCP.instruction(agent_id, task.task_id, task.payload,
              priority: Map.get(task, :priority, 0),
              lease_ms: Map.get(task, :lease_ms, 300_000)
            )

          {:ok, json} = OSCP.encode(event)

          conn
          |> put_resp_content_type("application/cloudevents+json")
          |> send_resp(200, json)

        :empty ->
          send_resp(conn, 204, "")
      end
    catch
      :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
    end
  end

  # ── GET /:agent_id ─────────────────────────────────────────────────

  get "/:agent_id" do
    agent_id = conn.params["agent_id"]

    try do
      case Fleet.get_agent(agent_id) do
        {:ok, agent} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(agent))

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Agent #{agent_id} not found")
      end
    catch
      :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
    end
  end

  # ── POST /dispatch ─────────────────────────────────────────────────

  post "/dispatch" do
    with %{"agent_id" => agent_id, "instruction" => instruction} <- conn.body_params do
      try do
        task_id = "fleet_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
        Tasks.enqueue(task_id, agent_id, %{instruction: instruction})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, Jason.encode!(%{status: "dispatched", task_id: task_id}))
      catch
        :exit, _ -> json_error(conn, 503, "fleet_unavailable", "Fleet management not enabled")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing: agent_id, instruction")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Fleet endpoint not found")
  end
end
