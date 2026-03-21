defmodule OptimalSystemAgent.Channels.HTTP.API.ApprovalRoutes do
  @moduledoc """
  Approval workflow routes for the OSA HTTP API.

  Forwarded prefix: /approvals

  Effective endpoints:
    GET  /approvals                    → List all approvals
    POST /approvals                    → Create a new approval request
    GET  /approvals/:id                → Get approval by ID
    POST /approvals/:id/approve        → Approve a request
    POST /approvals/:id/reject         → Reject a request
    POST /approvals/:id/request-revision → Request revision

  Storage: ~/.osa/approvals.json
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — list all approvals ──────────────────────────────────────

  get "/" do
    approvals = read_data()
    json(conn, 200, %{approvals: approvals, count: length(approvals)})
  end

  # ── POST / — create an approval request ─────────────────────────────

  post "/" do
    try do
      case conn.body_params do
        %{"title" => title} when is_binary(title) and title != "" ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          approval = %{
            "id" => generate_id("apr"),
            "title" => title,
            "description" => Map.get(conn.body_params, "description", ""),
            "status" => "pending",
            "requested_by" => Map.get(conn.body_params, "requested_by", "orchestrator"),
            "decided_by" => nil,
            "decision_at" => nil,
            "created_at" => now
          }

          approvals = read_data()
          write_data([approval | approvals])

          Logger.info("[ApprovalRoutes] Created approval #{approval["id"]}: #{title}")
          json(conn, 201, approval)

        _ ->
          json_error(conn, 400, "invalid_request", "Missing required field: title")
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to create approval request")
    end
  end

  # ── GET /:id — get approval by ID ───────────────────────────────────

  get "/:id" do
    id = conn.params["id"]

    case find_by_id(read_data(), id) do
      nil -> json_error(conn, 404, "not_found", "Approval not found")
      approval -> json(conn, 200, approval)
    end
  end

  # ── POST /:id/approve — approve a request ───────────────────────────

  post "/:id/approve" do
    id = conn.params["id"]
    transition_status(conn, id, "approved")
  end

  # ── POST /:id/reject — reject a request ─────────────────────────────

  post "/:id/reject" do
    id = conn.params["id"]
    transition_status(conn, id, "rejected")
  end

  # ── POST /:id/request-revision — request revision ───────────────────

  post "/:id/request-revision" do
    id = conn.params["id"]

    try do
      approvals = read_data()

      case find_by_id(approvals, id) do
        nil ->
          json_error(conn, 404, "not_found", "Approval not found")

        existing ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          decided_by = get_in(conn.body_params, ["decided_by"]) || "user"
          reason = Map.get(conn.body_params, "reason")

          updated =
            existing
            |> Map.put("status", "revision_requested")
            |> Map.put("decided_by", decided_by)
            |> Map.put("decision_at", now)
            |> then(fn a -> if reason, do: Map.put(a, "reason", reason), else: a end)

          new_approvals =
            Enum.map(approvals, fn a -> if a["id"] == id, do: updated, else: a end)

          write_data(new_approvals)

          Logger.info("[ApprovalRoutes] Revision requested for approval #{id} by #{decided_by}")
          json(conn, 200, updated)
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to request revision")
    end
  end

  # ── catch-all ────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Approval endpoint not found")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp data_path do
    Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
    |> Path.expand()
    |> Path.join("approvals.json")
  end

  defp read_data do
    path = data_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_list(parsed) do
      parsed
    else
      _ -> []
    end
  rescue
    e ->
      Logger.warning("[ApprovalRoutes] Failed to read approvals: #{Exception.message(e)}")
      []
  end

  defp write_data(approvals) do
    path = data_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(approvals, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.warning("[ApprovalRoutes] Failed to encode approvals: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[ApprovalRoutes] Failed to write approvals: #{Exception.message(e)}")
  end

  defp find_by_id(approvals, id) do
    Enum.find(approvals, fn a -> a["id"] == id end)
  end

  defp generate_id(prefix) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    "#{prefix}_#{suffix}"
  end

  # Shared transition helper for approve/reject — both only differ in target status.
  defp transition_status(conn, id, status) do
    try do
      approvals = read_data()

      case find_by_id(approvals, id) do
        nil ->
          json_error(conn, 404, "not_found", "Approval not found")

        existing ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          decided_by = get_in(conn.body_params, ["decided_by"]) || "user"

          updated =
            existing
            |> Map.put("status", status)
            |> Map.put("decided_by", decided_by)
            |> Map.put("decision_at", now)

          new_approvals =
            Enum.map(approvals, fn a -> if a["id"] == id, do: updated, else: a end)

          write_data(new_approvals)

          Logger.info("[ApprovalRoutes] Approval #{id} #{status} by #{decided_by}")
          json(conn, 200, updated)
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to update approval status")
    end
  end
end
