defmodule OptimalSystemAgent.Channels.HTTP.API.AgentStateRoutes do
  @moduledoc """
  Agent introspection routes. Forwarded from /agent in the parent router.

  Effective routes:
    GET /state         — full session snapshot (existing)
    GET /state/summary — TUI-friendly compact summary
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Tools.Registry, as: ToolsRegistry

  plug(:match)
  plug(:dispatch)

  get "/state" do
    snap = build_summary()
    json(conn, 200, snap)
  end

  # GET /state/summary — compact TUI-friendly aggregate
  get "/state/summary" do
    summary = build_summary()
    json(conn, 200, summary)
  end

  match _ do
    json_error(conn, 404, "not_found", "Not found")
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp build_summary do
    active_sessions = count_sessions()
    tools_count = count_tools()
    {current_provider, current_model} = current_model_info()
    memory_mb = total_memory_mb()
    uptime_seconds = uptime_seconds()
    last_messages = recent_message_previews(3)

    status =
      cond do
        active_sessions > 0 -> "active"
        true -> "idle"
      end

    %{
      active_sessions: active_sessions,
      tools_count: tools_count,
      current_provider: current_provider,
      current_model: current_model,
      memory_mb: memory_mb,
      uptime_seconds: uptime_seconds,
      last_messages: last_messages,
      status: status,
      timestamp: DateTime.utc_now()
    }
  end

  defp count_sessions do
    Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> length()
  rescue
    _ -> 0
  end

  defp count_tools do
    ToolsRegistry.list_tools_direct() |> length()
  rescue
    _ -> 0
  end

  defp current_model_info do
    provider =
      Application.get_env(:optimal_system_agent, :default_provider, :ollama)
      |> to_string()

    # Runtime.Identity, not a hand-rolled chain — the `:ollama_model` fallback
    # (and its hardcoded literal) reported an Ollama model for every provider.
    {provider, OptimalSystemAgent.Runtime.Identity.model()}
  end

  defp total_memory_mb do
    bytes = :erlang.memory(:total)
    Float.round(bytes / 1_048_576, 1)
  rescue
    _ -> 0.0
  end

  defp uptime_seconds do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1_000)
  rescue
    _ -> 0
  end

  # Returns up to `n` recent message previews from all active sessions.
  # Introspection module not yet available — returns empty for now.
  defp recent_message_previews(_n), do: []
end
