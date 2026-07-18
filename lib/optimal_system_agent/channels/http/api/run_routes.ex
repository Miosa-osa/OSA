defmodule OptimalSystemAgent.Channels.HTTP.API.RunRoutes do
  @moduledoc """
  Agent run dashboard — a read-only view over `RunStore` plus a cancel path.

    GET  /runs            — list agent runs (active + background), newest first
    GET  /runs/:id        — single run detail
    POST /runs/:id/cancel — request cancellation of a run by id

  This module is forwarded to from the parent router at /runs, so routes are
  relative to that prefix. `RunStore` remains the single source of truth; these
  routes only read it. Cancellation reuses the existing loop cancel path
  (ETS cancel flag propagated to sub-agents), keyed by run id.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Runtime.SessionManager

  plug(:match)
  plug(:dispatch)

  # ── GET / — list runs ──────────────────────────────────────────────
  #
  # Optional query params:
  #   ?status=running|completed|failed|cancelled  — filter by status
  #   ?limit=N                                     — cap results (default 50)

  get "/" do
    conn = Plug.Conn.fetch_query_params(conn)
    status = parse_status(conn.query_params["status"])
    limit = parse_positive_int(conn.query_params["limit"], 50)

    runs =
      RunStore.list(limit: limit, status: status)
      |> Enum.map(&summarize_run/1)

    active = Enum.filter(runs, &(&1.status == "running"))

    json(conn, 200, %{
      runs: runs,
      active: active,
      active_count: length(active),
      count: length(runs)
    })
  end

  # ── GET /:id — single run ──────────────────────────────────────────

  get "/:id" do
    run_id = conn.params["id"]

    case RunStore.get(run_id) do
      nil ->
        json_error(conn, 404, "not_found", "No run found for #{run_id}")

      run ->
        json(conn, 200, summarize_run(run))
    end
  end

  # ── GET /:id/transcript — full sidechain transcript (nested Ctrl+O view) ──

  get "/:id/transcript" do
    run_id = conn.params["id"]

    case RunStore.transcript(run_id) do
      {:ok, content} ->
        json(conn, 200, %{id: run_id, transcript: content})

      {:error, msg} ->
        json_error(conn, 404, "not_found", msg)
    end
  end

  # ── POST /:id/cancel — cancel a run ────────────────────────────────

  post "/:id/cancel" do
    run_id = conn.params["id"]

    case RunStore.get(run_id) do
      nil ->
        json_error(conn, 404, "not_found", "No run found for #{run_id}")

      _run ->
        # Reuse the loop cancel path — sets the ETS cancel flag the ReactLoop
        # checks each iteration, and propagates to registered sub-agents.
        SessionManager.cancel(run_id)
        Logger.info("[RunRoutes] cancel requested for run=#{run_id}")
        json(conn, 200, %{status: "cancelling", run_id: run_id})
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Run endpoint not found")
  end

  # ── Private ────────────────────────────────────────────────────────

  # Project a RunStore record onto the dashboard shape.
  defp summarize_run(run) do
    %{
      id: run.agent_id,
      role: run.role,
      status: to_string(run.status),
      parent_session_id: run.parent_session_id,
      started_at: iso8601(run.started_at),
      completed_at: iso8601(run.completed_at),
      duration_ms: run.duration_ms,
      tokens: run.tokens_used,
      tool_count: run.tool_count,
      task_preview: String.slice(run.task || "", 0, 120)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(_), do: nil

  defp parse_status(nil), do: nil
  defp parse_status("running"), do: :running
  defp parse_status("completed"), do: :completed
  defp parse_status("failed"), do: :failed
  defp parse_status("cancelled"), do: :cancelled
  defp parse_status(_), do: nil
end
