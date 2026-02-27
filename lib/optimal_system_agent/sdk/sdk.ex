defmodule OptimalSystemAgent.SDK do
  @moduledoc """
  Core SDK module — the internal implementation for `OSA.SDK`.

  Provides `query/2`, `launch_swarm/2`, and `execute_plan/2` which
  orchestrate the full agent lifecycle: session management, hook injection,
  Loop invocation, Bus event translation, and message formatting.

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
  - `:provider` — LLM provider atom (e.g., `:anthropic`, `:openai`, `:ollama`)
  - `:model` — model name string (e.g., `"claude-sonnet-4-6"`)
  - `:max_budget_usd` — budget limit per session
  - `:on_message` — callback `(Message.t() -> any())` for streaming events
  - `:timeout` — call timeout in ms (default: 120_000)

  ## Returns
  - `{:ok, [Message.t()]}` — list of messages (user input + assistant/plan response)
  - `{:error, term()}` — on failure
  """
  @spec query(String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, term()}
  def query(message, opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, &generate_id/0)
    on_message = Keyword.get(opts, :on_message)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # 1. Register SDK tools if provided
    register_sdk_tools(Keyword.get(opts, :tools, []))

    # 2. Build extra_tools for this session
    extra_tools = Keyword.get(opts, :extra_tools, [])

    # 3. Register permission hook if non-bypass
    permission = Keyword.get(opts, :permission, :default)
    register_permission_hook(permission, session_id)

    # 4. Subscribe to Bus events for full streaming
    bus_refs = subscribe_bus(session_id, on_message)

    # 5. Create or resume session (with provider/model passthrough)
    session_opts = [
      session_id: session_id,
      user_id: Keyword.get(opts, :user_id),
      channel: :sdk,
      extra_tools: extra_tools,
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model)
    ]

    case Session.resume(session_id, session_opts) do
      {:ok, ^session_id} ->
        # 6. Process message through the Loop (with provider/model + timeout)
        loop_opts = [skip_plan: permission == :bypass]
        loop_opts = maybe_put(loop_opts, :provider, Keyword.get(opts, :provider))
        loop_opts = maybe_put(loop_opts, :model, Keyword.get(opts, :model))

        result =
          try do
            GenServer.call(
              {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}},
              {:process, message, loop_opts},
              timeout
            )
          catch
            :exit, {:timeout, _} -> {:error, :timeout}
            :exit, reason -> {:error, reason}
          end

        # 7. Unsubscribe from Bus
        unsubscribe_bus(bus_refs)

        # 8. Translate result to SDK Messages
        translate_result(result, message, session_id, on_message)

      {:error, reason} ->
        unsubscribe_bus(bus_refs)
        {:error, reason}
    end
  end

  @doc """
  Execute an approved plan from a previous `query/2` that returned `:plan`.

  Re-sends the original message with `skip_plan: true` to bypass plan mode
  and execute normally with full tool access.

  ## Options
  Same as `query/2` — session_id is required to resume the same session.
  """
  @spec execute_plan(String.t(), String.t(), keyword()) :: {:ok, [Message.t()]} | {:error, term()}
  def execute_plan(session_id, message, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:permission, :bypass)

    on_message = Keyword.get(opts, :on_message)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    bus_refs = subscribe_bus(session_id, on_message)

    loop_opts = [skip_plan: true]
    loop_opts = maybe_put(loop_opts, :provider, Keyword.get(opts, :provider))
    loop_opts = maybe_put(loop_opts, :model, Keyword.get(opts, :model))

    result =
      try do
        GenServer.call(
          {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}},
          {:process, message, loop_opts},
          timeout
        )
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end

    unsubscribe_bus(bus_refs)
    translate_result(result, message, session_id, on_message)
  end

  @doc """
  Launch a swarm of agents on a task.

  Uses the Agent.Orchestrator to decompose the task and execute with
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

  @doc "Define a custom tool (delegates to `SDK.Tool.define/4`)."
  @spec define_tool(String.t(), String.t(), map(), function()) :: :ok | {:error, term()}
  def define_tool(name, description, parameters, handler) do
    Tool.define(name, description, parameters, handler)
  end

  @doc "Define a custom agent (delegates to `SDK.Agent.define/2`)."
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
      nil -> :ok
      hook_fn ->
        Hook.register(:pre_tool_use, "sdk_permission_#{session_id}", hook_fn, priority: 1)
    end
  end

  # Subscribe to multiple Bus event types for full streaming
  defp subscribe_bus(session_id, on_message) when is_function(on_message, 1) do
    tool_ref = Bus.register_handler(:tool_call, fn payload ->
      if Map.get(payload, :session_id) == session_id or not Map.has_key?(payload, :session_id) do
        phase = Map.get(payload, :phase, :start)
        name = Map.get(payload, :name, "unknown")
        duration = Map.get(payload, :duration_ms)

        content =
          if phase == :end and duration,
            do: "Tool completed: #{name} (#{duration}ms)",
            else: "Tool: #{name}"

        on_message.(Message.progress(content, session_id: session_id, metadata: payload))
      end
    end)

    llm_ref = Bus.register_handler(:llm_response, fn payload ->
      if Map.get(payload, :session_id) == session_id do
        usage = Map.get(payload, :usage, %{})
        duration = Map.get(payload, :duration_ms, 0)

        on_message.(Message.budget(
          %{usage: usage, duration_ms: duration},
          session_id: session_id
        ))
      end
    end)

    response_ref = Bus.register_handler(:agent_response, fn payload ->
      if Map.get(payload, :session_id) == session_id do
        signal = Map.get(payload, :signal)
        if signal do
          on_message.(Message.system(
            "Signal: #{signal.mode}/#{signal.genre} weight=#{signal.weight}",
            session_id: session_id,
            metadata: %{signal: signal}
          ))
        end
      end
    end)

    [tool_call: tool_ref, llm_response: llm_ref, agent_response: response_ref]
  end

  defp subscribe_bus(_session_id, _), do: []

  defp unsubscribe_bus([]), do: :ok

  defp unsubscribe_bus(refs) when is_list(refs) do
    Enum.each(refs, fn {event_type, ref} ->
      try do
        Bus.unregister_handler(event_type, ref)
      rescue
        _ -> :ok
      end
    end)
  end

  defp unsubscribe_bus(_), do: :ok

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
