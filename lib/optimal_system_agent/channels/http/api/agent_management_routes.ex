defmodule OptimalSystemAgent.Channels.HTTP.API.AgentManagementRoutes do
  @moduledoc """
  Agent management routes — definitions, lifecycle, and hierarchy.

    GET  /agents           — list all agent definitions with active session status
    GET  /agents/hierarchy — agent org-chart tree
    GET  /agents/:id       — single agent definition
    POST /agents/:id/pause — pause an agent session (stub, returns 202)
    POST /agents/:id/resume — resume an agent session (stub, returns 202)
    DELETE /agents/:id     — terminate an agent session

  This module is forwarded to from the parent router at /agents, so routes
  are relative to that prefix. Agent definitions are loaded from AGENT.md
  files stored in :persistent_term — no database involved.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agents.Registry, as: AgentRegistry
  alias OptimalSystemAgent.Agent.SubagentControl

  plug(:match)
  plug(:dispatch)

  # ── GET / — list all agent definitions ────────────────────────────

  get "/" do
    definitions = safe_list_agents()
    active_session_ids = safe_list_session_ids()

    agents =
      Enum.map(definitions, fn agent ->
        active_count = count_active_sessions(agent.name, active_session_ids)

        %{
          id: agent.name,
          name: agent.name,
          description: agent[:description] || "",
          tier: to_string(agent[:tier] || "specialist"),
          status: if(active_count > 0, do: "active", else: "available"),
          active_sessions: active_count,
          capabilities: agent[:triggers] || []
        }
      end)

    json(conn, 200, %{agents: agents, count: length(agents)})
  end

  # ── GET /hierarchy — agent org-chart ──────────────────────────────
  #
  # Must appear before /:id so the literal "hierarchy" segment is matched first.

  get "/hierarchy" do
    definitions = safe_list_agents()

    # Index by name for O(1) child lookup
    by_name =
      Map.new(definitions, fn agent ->
        {agent.name,
         %{
           name: agent.name,
           tier: to_string(agent[:tier] || "specialist"),
           reports_to: agent[:reports_to],
           children: []
         }}
      end)

    # Attach each agent to its parent's children list
    {tree_map, roots} =
      Enum.reduce(by_name, {by_name, []}, fn {name, node}, {acc, root_acc} ->
        case node.reports_to do
          nil ->
            {acc, [name | root_acc]}

          parent_name when is_binary(parent_name) ->
            if Map.has_key?(acc, parent_name) do
              updated =
                update_in(acc, [parent_name, :children], fn children ->
                  [name | children]
                end)

              {updated, root_acc}
            else
              # Parent referenced but not in registry — treat as root
              {acc, [name | root_acc]}
            end

          _ ->
            {acc, [name | root_acc]}
        end
      end)

    # Recursively build nested node structures from the tree_map
    root_nodes =
      roots
      |> Enum.sort()
      |> Enum.map(fn name -> build_node(name, tree_map) end)

    json(conn, 200, %{hierarchy: root_nodes})
  end

  # GET /:id/runtime and /:id/control - delegated-run control plane

  get "/:id/runtime" do
    case SubagentControl.snapshot(conn.params["id"]) do
      {:ok, snapshot} -> json(conn, 200, snapshot)
      {:error, :not_found} -> json_error(conn, 404, "not_found", "Agent run not found")
    end
  end

  post "/:id/control" do
    action = conn.body_params["action"]

    case SubagentControl.command(conn.params["id"], action, conn.body_params) do
      {:ok, snapshot} ->
        json(conn, 200, %{status: "accepted", agent: snapshot})

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Agent run not found")

      {:error, {:unsupported_action, value}} ->
        json_error(conn, 400, "unsupported_action", "Unsupported agent action: #{value}")

      {:error, reason} ->
        json_error(conn, 409, "control_failed", inspect(reason))
    end
  end

  # ── GET /:id — single agent definition ────────────────────────────

  get "/:id" do
    agent_id = conn.params["id"]

    case safe_get_agent(agent_id) do
      nil ->
        json_error(conn, 404, "not_found", "Agent #{agent_id} not found")

      agent ->
        body = %{
          id: agent.name,
          name: agent.name,
          description: agent[:description] || "",
          tier: to_string(agent[:tier] || "specialist"),
          capabilities: agent[:triggers] || [],
          system_prompt: agent[:system_prompt] || ""
        }

        json(conn, 200, body)
    end
  end

  # ── POST /:id/pause — pause agent session ──────────────────────────

  post "/:id/pause" do
    agent_id = conn.params["id"]

    try do
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
        [{_pid, _}] ->
          # Cooperative pause: set an ETS flag the ReactLoop checks each iteration
          # and soft-stops on (replaces the unsafe :sys.suspend which blocked
          # every GenServer.call to the loop and never auto-resumed).
          set_pause_flag(agent_id, true)
          Logger.info("[AgentMgmt] paused agent=#{agent_id}")
          json(conn, 200, %{status: "paused", agent: agent_id})

        [] ->
          json_error(conn, 404, "not_found", "Agent #{agent_id} not found")
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to pause agent")
    end
  end

  # ── POST /:id/resume — resume agent session ──────────────────────

  post "/:id/resume" do
    agent_id = conn.params["id"]

    try do
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
        [{_pid, _}] ->
          set_pause_flag(agent_id, false)
          Logger.info("[AgentMgmt] resumed agent=#{agent_id}")
          json(conn, 200, %{status: "resumed", agent: agent_id})

        [] ->
          json_error(conn, 404, "not_found", "Agent #{agent_id} not found")
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to resume agent")
    end
  end

  # ── DELETE /:id — terminate an agent session ──────────────────────

  delete "/:id" do
    agent_id = conn.params["id"]

    try do
      case safe_lookup_session(agent_id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal)
            Logger.info("[AgentMgmt] terminated session pid=#{inspect(pid)} agent=#{agent_id}")
            json(conn, 200, %{status: "terminated", agent: agent_id})
          rescue
            _ ->
              # Process already gone — still a success from the caller's perspective
              json(conn, 200, %{status: "terminated", agent: agent_id})
          end

        [] ->
          json_error(conn, 404, "not_found", "No active session found for agent #{agent_id}")

        :error ->
          json_error(conn, 404, "not_found", "No active session found for agent #{agent_id}")
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to terminate agent")
    end
  end

  # ── catch-all ─────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Agent endpoint not found")
  end

  # ── Private helpers ───────────────────────────────────────────────

  # Safely call AgentRegistry.list/0 — returns [] if registry not ready.
  defp safe_list_agents do
    AgentRegistry.list()
  rescue
    _ -> []
  end

  # Safely call AgentRegistry.get/1 — returns nil if registry not ready.
  defp safe_get_agent(name) do
    AgentRegistry.get(name)
  rescue
    _ -> nil
  end

  # Safely enumerate all registered session IDs from the SessionRegistry.
  # Returns [] when the Registry process is not running.
  defp safe_list_session_ids do
    Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  # Safely look up a session by exact ID. Returns a match list or :error.
  defp safe_lookup_session(session_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
  rescue
    _ -> :error
  end

  # Count active sessions that belong to this agent. Matches an exact session id
  # or the trailing name segment of a structured subagent id
  # ("agent:<parent>:<name>") — avoids the old String.contains? false positives
  # (agent "go" matching "goose-123").
  defp count_active_sessions(agent_name, session_ids) do
    Enum.count(session_ids, fn sid ->
      is_binary(sid) and session_matches_agent?(sid, agent_name)
    end)
  end

  defp session_matches_agent?(sid, agent_name) do
    cond do
      sid == agent_name ->
        true

      String.starts_with?(sid, "agent:") ->
        case String.split(sid, ":") do
          parts when length(parts) >= 3 -> List.last(parts) == agent_name
          _ -> false
        end

      true ->
        false
    end
  end

  # Set/clear the cooperative pause flag for an agent/session. The ReactLoop
  # reads :osa_agent_pause_flags each iteration and soft-stops when set.
  defp set_pause_flag(agent_id, true) do
    :ets.insert(:osa_agent_pause_flags, {agent_id, true})
  rescue
    ArgumentError -> :ok
  end

  defp set_pause_flag(agent_id, false) do
    :ets.delete(:osa_agent_pause_flags, agent_id)
  rescue
    ArgumentError -> :ok
  end

  # Build a hierarchy node map, recursively expanding children.
  defp build_node(name, tree_map) do
    case Map.get(tree_map, name) do
      nil ->
        %{name: name, tier: "specialist", reports_to: nil, children: []}

      node ->
        child_nodes =
          node.children
          |> Enum.sort()
          |> Enum.map(fn child_name -> build_node(child_name, tree_map) end)

        %{node | children: child_nodes}
    end
  end
end
