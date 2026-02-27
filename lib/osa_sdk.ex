defmodule OSA.SDK do
  @moduledoc """
  Public facade for the OSA SDK.

  The entry point for external Elixir applications to embed the full OSA
  agent runtime. All functions delegate to internal `OptimalSystemAgent.SDK.*`
  modules.

  ## Quick Start

      # Simple query
      {:ok, messages} = OSA.SDK.query("What is 2+2?")

      # With options
      {:ok, messages} = OSA.SDK.query("Fix the bug in auth.ex", [
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        permission: :accept_edits
      ])

  ## Embedded Mode

  Add to your supervision tree for a standalone OSA runtime:

      config = %OptimalSystemAgent.SDK.Config{
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        permission: :accept_edits,
        http_port: 8090
      }

      children = [
        {OptimalSystemAgent.SDK.Supervisor, config}
      ]

  ## Custom Tools

      OSA.SDK.define_tool(
        "weather",
        "Get weather for a city",
        %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}, "required" => ["city"]},
        fn %{"city" => city} -> {:ok, "72°F in \#{city}"} end
      )

  ## Custom Agents

      OSA.SDK.define_agent("my-reviewer", %{
        tier: :specialist,
        role: :qa,
        description: "Domain-specific code reviewer",
        skills: ["file_read"],
        triggers: ["domain review"],
        territory: ["*.ex"],
        escalate_to: nil,
        prompt: "You are a domain-specific reviewer..."
      })
  """

  # ── Query & Swarm ────────────────────────────────────────────────

  @doc """
  Send a message through the full OSA agent pipeline.

  See `OptimalSystemAgent.SDK.query/2` for full documentation.
  """
  defdelegate query(message, opts \\ []), to: OptimalSystemAgent.SDK

  @doc """
  Launch a multi-agent swarm on a task.

  See `OptimalSystemAgent.SDK.launch_swarm/2` for full documentation.
  """
  defdelegate launch_swarm(task, opts \\ []), to: OptimalSystemAgent.SDK

  @doc """
  Execute an approved plan from a previous query that returned :plan.

  See `OptimalSystemAgent.SDK.execute_plan/3` for full documentation.
  """
  defdelegate execute_plan(session_id, message, opts \\ []), to: OptimalSystemAgent.SDK

  # ── Tool Registration ────────────────────────────────────────────

  @doc """
  Define a custom tool via closure.

  See `OptimalSystemAgent.SDK.Tool.define/4` for full documentation.
  """
  defdelegate define_tool(name, description, parameters, handler),
    to: OptimalSystemAgent.SDK.Tool,
    as: :define

  @doc "Remove a previously defined SDK tool."
  defdelegate undefine_tool(name), to: OptimalSystemAgent.SDK.Tool, as: :undefine

  # ── Agent Registration ───────────────────────────────────────────

  @doc """
  Define a custom agent at runtime.

  See `OptimalSystemAgent.SDK.Agent.define/2` for full documentation.
  """
  defdelegate define_agent(name, definition),
    to: OptimalSystemAgent.SDK.Agent,
    as: :define

  @doc "Remove a previously defined SDK agent."
  defdelegate undefine_agent(name), to: OptimalSystemAgent.SDK.Agent, as: :undefine

  # ── Hook Registration ────────────────────────────────────────────

  @doc """
  Register a hook for an agent lifecycle event.

  See `OptimalSystemAgent.SDK.Hook.register/4` for full documentation.
  """
  defdelegate register_hook(event, name, handler, opts \\ []),
    to: OptimalSystemAgent.SDK.Hook,
    as: :register

  # ── Session Management ───────────────────────────────────────────

  @doc "Create a new agent session."
  defdelegate create_session(opts \\ []), to: OptimalSystemAgent.SDK.Session, as: :create

  @doc "Resume an existing session."
  defdelegate resume_session(session_id, opts \\ []),
    to: OptimalSystemAgent.SDK.Session,
    as: :resume

  @doc "Close a session."
  defdelegate close_session(session_id), to: OptimalSystemAgent.SDK.Session, as: :close

  @doc "List active sessions."
  defdelegate list_sessions(), to: OptimalSystemAgent.SDK.Session, as: :list

  @doc "Get messages for a session."
  defdelegate get_messages(session_id), to: OptimalSystemAgent.SDK.Session, as: :get_messages

  # ── Memory ───────────────────────────────────────────────────────

  @doc "Recall all persistent memories."
  defdelegate recall(), to: OptimalSystemAgent.SDK.Memory

  @doc "Recall memories relevant to a query within token budget."
  defdelegate recall_relevant(message, max_tokens \\ 2000), to: OptimalSystemAgent.SDK.Memory

  @doc "Save an insight to persistent memory."
  defdelegate remember(content, category \\ "general"), to: OptimalSystemAgent.SDK.Memory

  @doc "Search memories by keyword."
  defdelegate search_memory(query, opts \\ []), to: OptimalSystemAgent.SDK.Memory, as: :search

  @doc "Load a session's message history."
  defdelegate load_session(session_id), to: OptimalSystemAgent.SDK.Memory

  @doc "Get memory statistics."
  defdelegate memory_stats(), to: OptimalSystemAgent.SDK.Memory, as: :stats

  # ── Budget ───────────────────────────────────────────────────────

  @doc "Check if current spending is within budget limits."
  defdelegate check_budget(), to: OptimalSystemAgent.SDK.Budget, as: :check

  @doc "Get full budget status: limits, spent, remaining, reset times."
  defdelegate budget_status(), to: OptimalSystemAgent.SDK.Budget, as: :status

  @doc "Record an API cost entry."
  defdelegate record_cost(provider, model, tokens_in, tokens_out, session_id),
    to: OptimalSystemAgent.SDK.Budget

  @doc "Calculate USD cost for token counts (pure function)."
  defdelegate calculate_cost(provider, tokens_in, tokens_out),
    to: OptimalSystemAgent.SDK.Budget

  @doc "Set daily budget limit in USD."
  defdelegate set_daily_limit(usd), to: OptimalSystemAgent.SDK.Budget

  # ── Signal Theory ────────────────────────────────────────────────

  @doc "Classify a message into its Signal Theory 5-tuple."
  defdelegate classify_signal(message, channel \\ :sdk), to: OptimalSystemAgent.SDK.Signal, as: :classify

  @doc "Calculate Shannon weight of a message (0.0-1.0)."
  defdelegate signal_weight(message), to: OptimalSystemAgent.SDK.Signal, as: :weight

  # ── Tiers & Models ──────────────────────────────────────────────

  @doc "Get model name for a tier on a given provider."
  defdelegate model_for(tier, provider), to: OptimalSystemAgent.SDK.Tier

  @doc "Get model for a named agent (tier-based routing)."
  defdelegate model_for_agent(agent_name), to: OptimalSystemAgent.SDK.Tier

  @doc "Get token budget breakdown for a tier."
  defdelegate budget_for(tier), to: OptimalSystemAgent.SDK.Tier

  @doc "Get all tier configurations."
  defdelegate all_tiers(), to: OptimalSystemAgent.SDK.Tier, as: :all

  @doc "List all supported LLM providers."
  defdelegate supported_providers(), to: OptimalSystemAgent.SDK.Tier

  @doc "Map complexity score (1-10) to tier."
  defdelegate tier_for_complexity(complexity), to: OptimalSystemAgent.SDK.Tier

  # ── Commands ─────────────────────────────────────────────────────

  @doc "Execute a slash command programmatically."
  defdelegate execute_command(input, session_id \\ "sdk"),
    to: OptimalSystemAgent.SDK.Command,
    as: :execute

  # ── MCP ──────────────────────────────────────────────────────────

  @doc "List all configured MCP servers."
  defdelegate list_mcp_servers(), to: OptimalSystemAgent.SDK.MCP, as: :list_servers

  @doc "List all MCP-provided tools registered in Skills.Registry."
  defdelegate list_mcp_tools(), to: OptimalSystemAgent.SDK.MCP, as: :list_tools

  # ── Convenience ──────────────────────────────────────────────────

  @doc "Alias for the Config struct module."
  def config, do: OptimalSystemAgent.SDK.Config

  @doc "Alias for the Message struct module."
  def message, do: OptimalSystemAgent.SDK.Message

  @doc "Alias for the Permission module."
  def permission, do: OptimalSystemAgent.SDK.Permission
end
