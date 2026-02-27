defmodule OptimalSystemAgent.SDK do
  @moduledoc """
  Core SDK module — the internal implementation for `OSA.SDK`.

  Provides `query/2` and `launch_swarm/2` which orchestrate the full
  agent lifecycle: session management, hook injection, Loop invocation,
  Bus event translation, and message formatting.

  ## Quick Start

      {:ok, messages} = OptimalSystemAgent.SDK.query("What is 2+2?")
      # => {:ok, [%SDK.Message{type: :assistant, content: "2+2 = 4", ...}]}

  ## With Options

      {:ok, messages} = OptimalSystemAgent.SDK.query("Fix the bug", [
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        session_id: "my-session",
        permission: :accept_edits,
        max_budget_usd: 1.0,
        on_message: fn msg -> IO.inspect(msg) end,
        timeout: 120_000
      ])
  """

  alias OptimalSystemAgent.SDK.{Message, Session, Permission, Hook, Tool}
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Events.Bus

  @default_timeout 120_000

  @doc """
  Send a message through the full OSA agent pipeline.

  Creates or resumes a session, registers any SDK tools and permission hooks,
  subscribes to Bus events, calls `Loop.process_message/3`, and translates
  the response into `SDK.Message` structs.

  ## Options
  - `:session_id` — reuse an existing session (auto-generated if omitted)
  - `:user_id` — user identifier
  - `:tools` — list of `{name, description, parameters, handler}` tuples to register
  - `:extra_tools` — tool definition maps passed directly to Loop (no registration)
  - `:permission` — permission mode (`:default`, `:accept_edits`, `:plan`, `:bypass`, `:deny_all`)
  - `:provider` — LLM provider atom
  - `:model` — model name string
  - `:max_budget_usd` — budget limit (not yet enforced, reserved)
  - `:on_message` — callback `(Message.t() -> any())` for streaming
  - `:timeout` — call timeout in ms (default: 120_000)

  ## Returns
  - `{:ok, [Message.t()]}` — list of messages (user input + assistant response)
  - `{:error, term()}` — on failure
  """
  @spec query(String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, term()}
  def query(message, opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, fn -> generate_id() end)
    on_message = Keyword.get(opts, :on_message)
    _timeout = Keyword.get(opts, :timeout, @default_timeout)

    # 1. Register SDK tools if provided
    register_sdk_tools(Keyword.get(opts, :tools, []))

    # 2. Build extra_tools for this session
    extra_tools = Keyword.get(opts, :extra_tools, [])

    # 3. Register permission hook if non-bypass
    permission = Keyword.get(opts, :permission, :default)
    register_permission_hook(permission, session_id)

    # 4. Subscribe to Bus events for streaming
    bus_ref = subscribe_bus(session_id, on_message)

    # 5. Create or resume session
    session_opts = [
      session_id: session_id,
      user_id: Keyword.get(opts, :user_id),
      channel: :sdk,
      extra_tools: extra_tools
    ]

    case Session.resume(session_id, session_opts) do
      {:ok, ^session_id} ->
        # 6. Process message through the Loop
        result =
          try do
            Loop.process_message(session_id, message, skip_plan: permission == :bypass)
          catch
            :exit, {:timeout, _} -> {:error, :timeout}
            :exit, reason -> {:error, reason}
          end

        # 7. Unsubscribe from Bus
        unsubscribe_bus(bus_ref)

        # 8. Translate result to SDK Messages
        translate_result(result, message, session_id, on_message)

      {:error, reason} ->
        unsubscribe_bus(bus_ref)
        {:error, reason}
    end
  end

  @doc """
  Launch a swarm of agents on a task.

  Uses the Swarm.Orchestrator to decompose the task and execute with
  multiple agents in parallel.

  ## Options
  - `:pattern` — swarm pattern name (e.g., "code-analysis", "full-stack")
  - `:timeout_ms` — swarm timeout (default: 300_000)
  - `:max_agents` — max concurrent agents (default: 10)
  - `:on_message` — streaming callback

  ## Returns
  - `{:ok, task_id, [Message.t()]}` — task_id + final messages
  - `{:error, term()}` — on failure
  """
  @spec launch_swarm(String.t(), keyword()) :: {:ok, String.t(), [Message.t()]} | {:error, term()}
  def launch_swarm(task_description, opts \\ []) do
    alias OptimalSystemAgent.Agent.Orchestrator

    session_id = generate_id()
    on_message = Keyword.get(opts, :on_message)

    try do
      case Orchestrator.execute(task_description, session_id, opts) do
        {:ok, task_id, synthesis} ->
          msg = Message.assistant(synthesis, session_id: session_id)
          if on_message, do: on_message.(msg)
          {:ok, task_id, [msg]}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc """
  Define a custom tool (delegates to `SDK.Tool.define/4`).
  """
  @spec define_tool(String.t(), String.t(), map(), function()) :: :ok | {:error, term()}
  def define_tool(name, description, parameters, handler) do
    Tool.define(name, description, parameters, handler)
  end

  @doc """
  Define a custom agent (delegates to `SDK.Agent.define/2`).
  """
  @spec define_agent(String.t(), map()) :: :ok | {:error, term()}
  def define_agent(name, definition) do
    OptimalSystemAgent.SDK.Agent.define(name, definition)
  end

  # ── Private ──────────────────────────────────────────────────────

  defp register_sdk_tools(tools) do
    Enum.each(tools, fn {name, desc, params, handler} ->
      Tool.define(name, desc, params, handler)
    end)
  end

  defp register_permission_hook(permission, session_id) do
    case Permission.build_hook(permission) do
      nil ->
        :ok

      hook_fn ->
        Hook.register(
          :pre_tool_use,
          "sdk_permission_#{session_id}",
          hook_fn,
          priority: 1
        )
    end
  end

  defp subscribe_bus(session_id, on_message) when is_function(on_message, 1) do
    Bus.register_handler(:tool_call, fn payload ->
      if Map.get(payload, :session_id) == session_id do
        msg =
          Message.progress(
            "Tool: #{Map.get(payload, :name, "unknown")}",
            session_id: session_id,
            metadata: payload
          )

        on_message.(msg)
      end
    end)
  end

  defp subscribe_bus(_session_id, _), do: nil

  defp unsubscribe_bus(nil), do: :ok

  defp unsubscribe_bus(ref) do
    Bus.unregister_handler(:tool_call, ref)
  rescue
    _ -> :ok
  end

  defp translate_result(result, original_message, session_id, on_message) do
    user_msg = Message.user(original_message, session_id: session_id)

    case result do
      {:ok, response} ->
        assistant_msg = Message.assistant(response, session_id: session_id)
        if on_message, do: on_message.(assistant_msg)
        {:ok, [user_msg, assistant_msg]}

      {:plan, plan_text, signal} ->
        plan_msg = Message.plan(plan_text, signal, session_id: session_id)
        if on_message, do: on_message.(plan_msg)
        {:ok, [user_msg, plan_msg]}

      {:error, reason} ->
        error_msg = Message.error("#{inspect(reason)}", session_id: session_id)
        if on_message, do: on_message.(error_msg)
        {:error, reason}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
