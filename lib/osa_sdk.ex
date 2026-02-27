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

  # ── Convenience ──────────────────────────────────────────────────

  @doc "Alias for the Config struct module."
  def config, do: OptimalSystemAgent.SDK.Config

  @doc "Alias for the Message struct module."
  def message, do: OptimalSystemAgent.SDK.Message
end
