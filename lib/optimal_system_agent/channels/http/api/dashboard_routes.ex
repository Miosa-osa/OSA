defmodule OptimalSystemAgent.Channels.HTTP.API.DashboardRoutes do
  @moduledoc """
  Aggregated dashboard endpoint for the OSA frontend.

    GET /  — Single response with all data the dashboard needs.

  Every data source is independently wrapped in try/rescue so a single
  failing subsystem never crashes the endpoint.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — aggregate dashboard ────────────────────────────────────

  get "/" do
    active_agents = fetch_active_agents()
    active_sessions = fetch_active_sessions()
    memory_entries = fetch_memory_entries()
    scheduled_tasks = fetch_scheduled_tasks()
    provider = fetch_provider()
    model = fetch_model()
    uptime_seconds = fetch_uptime_seconds()
    memory_mb = fetch_memory_mb()
    tools_count = fetch_tools_count()

    status = if active_sessions > 0, do: "active", else: "idle"

    body =
      Jason.encode!(%{
        active_agents: active_agents,
        active_sessions: active_sessions,
        memory_entries: memory_entries,
        scheduled_tasks: scheduled_tasks,
        provider: provider,
        model: model,
        uptime_seconds: uptime_seconds,
        memory_mb: memory_mb,
        tools_count: tools_count,
        recent_activity: [],
        status: status
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Catch-all ─────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Dashboard endpoint not found")
  end

  # ── Private data fetchers ─────────────────────────────────────────

  defp fetch_active_agents do
    OptimalSystemAgent.Agents.Registry.list() |> length()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp fetch_active_sessions do
    Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> length()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp fetch_memory_entries do
    :ets.info(:osa_memory_entries, :size)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp fetch_scheduled_tasks do
    OptimalSystemAgent.Agent.Scheduler.list_jobs() |> length()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp fetch_provider do
    Application.get_env(:optimal_system_agent, :default_provider, :ollama) |> to_string()
  rescue
    _ -> "ollama"
  end

  defp fetch_model do
    (Application.get_env(:optimal_system_agent, :default_model) ||
       Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest"))
    |> to_string()
  rescue
    _ -> "llama3.2:latest"
  end

  defp fetch_uptime_seconds do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1_000)
  rescue
    _ -> 0
  end

  defp fetch_memory_mb do
    (:erlang.memory(:total) / 1_048_576) |> Float.round(1)
  rescue
    _ -> 0.0
  end

  defp fetch_tools_count do
    OptimalSystemAgent.Tools.Registry.list_tools_direct() |> length()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end
end
