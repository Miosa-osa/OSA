defmodule OptimalSystemAgent.Agent.Hooks do
  @moduledoc """
  Public facade and lifecycle owner for the agent hook system.

  The hook system is split into three concerns:

    * **Engine** — `OptimalSystemAgent.Agent.Hooks.Dispatch` — registration,
      priority ordering, return-value control (allow / deny / rewrite-input /
      rewrite-output / inject-context), per-hook timeout, fail-closed isolation
      and metrics. Pure mechanism, no business logic.
    * **Handlers** — `OptimalSystemAgent.Agent.Hooks.Handlers` — the concrete
      built-in behaviours (security, spend guard, MCP cache, cost, telemetry,
      learning, transcript, session cleanup, …).
    * **This module** — the stable public API (`register/4`, `run/2`,
      `run_async/2`, `list_hooks/0`, `metrics/0`) plus the GenServer that owns
      the ETS tables, installs the built-in handlers, and loads user-defined
      hooks at startup.

  ## Lifecycle events (Claude Code model)

      :session_start          — a session/loop is created
      :session_end            — a session/loop terminates
      :user_prompt_submit     — a user message enters the loop (can rewrite/block)
      :pre_tool_use           — before a tool runs (can rewrite args / deny)
      :post_tool_use          — after a tool runs (can rewrite output)
      :post_tool_use_failure  — after a tool errors/blocks
      :subagent_start         — a delegated subagent starts
      :subagent_stop          — a delegated subagent finishes
      :pre_compact            — before context compaction
      :post_compact           — after context compaction
      :post_response          — after a full assistant turn completes

  ## Handler return protocol

  See `OptimalSystemAgent.Agent.Hooks.Dispatch` for the full return protocol.
  In short a handler returns `{:ok, payload}` / `:allow` / `:skip` to continue,
  `{:block, reason}` (alias `{:deny, reason}`) to deny, `{:rewrite_input, input}`
  / `{:rewrite_output, output}` to mutate, or `{:inject_context, content}` to add
  context.

  ## User-defined hooks (extension points)

  Hooks can be added without recompiling in three ways, all of which route
  through `register/4`:

    * **Settings-driven shell hooks** — a `"hooks"` map in settings binds shell
      commands to events. Loaded by `Hooks.ShellHook.register_from_settings/0`.
    * **Settings-driven HTTP hooks** — POST an event payload to a URL. Loaded by
      `Hooks.HttpHook.register_from_settings/0`.
    * **Programmatic hooks** — call `Hooks.register(event, name, fun, opts)` from
      any startup code or via the SDK (`OptimalSystemAgent.SDK.register_hook/4`).

  Both settings loaders are invoked from `channels/starter.ex` at boot. New
  lifecycle events work with these loaders automatically: the settings key names
  the event atom, so a `"session_start"` or `"pre_compact"` entry binds to the
  new events with no further wiring.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Hooks.{Dispatch, Handlers}

  @type hook_event ::
          :session_start
          | :session_end
          | :user_prompt_submit
          | :pre_tool_use
          | :post_tool_use
          | :post_tool_use_failure
          | :subagent_start
          | :subagent_stop
          | :pre_compact
          | :post_compact
          | :pre_response
          | :post_response
          | :pre_session_resume
          | :session_error
          | :task_completed
          | :task_failed
          | :permission_request
          | :permission_granted
          | :permission_denied
          | :file_changed
          | :file_read
          | :worktree_create
          | :worktree_remove
          | :stop

  @type hook_fn :: Dispatch.hook_fn()
  @type hook_entry :: %{
          name: String.t(),
          event: hook_event(),
          handler: hook_fn(),
          priority: integer(),
          opts: keyword()
        }

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a hook for an event.

  Options:
    * `:priority` — lower runs first (default 50)
    * `:timeout_ms` — opt-in wall-clock timeout for this handler
    * `:fail_closed` — when timing out, deny the action (default false)
  """
  @spec register(hook_event(), String.t(), hook_fn(), keyword()) :: :ok
  def register(event, name, handler, opts \\ []) do
    priority = Keyword.get(opts, :priority, 50)
    hook_opts = Keyword.drop(opts, [:priority])
    GenServer.cast(__MODULE__, {:register, event, name, handler, priority, hook_opts})
  end

  @doc """
  Run all hooks for an event synchronously. Returns the final payload or a block
  reason. Executes in the caller's process (no GenServer call on the hot path).
  """
  @spec run(hook_event(), map()) :: {:ok, map()} | {:blocked, String.t()}
  defdelegate run(event, payload), to: Dispatch

  @doc """
  Run hooks asynchronously (fire-and-forget). Use for post-events whose results
  the caller does not need.
  """
  @spec run_async(hook_event(), map()) :: :ok
  defdelegate run_async(event, payload), to: Dispatch

  @doc "List registered hooks grouped by event."
  @spec list_hooks() :: %{hook_event() => [%{name: String.t(), priority: integer()}]}
  defdelegate list_hooks(), to: Dispatch

  @doc "Get hook execution metrics."
  @spec metrics() :: map()
  defdelegate metrics(), to: Dispatch

  @doc false
  def hooks_table_name, do: Dispatch.hooks_table_name()

  # ── GenServer Callbacks ────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Dispatch.ensure_tables()

    register_builtins()

    hook_count =
      try do
        :ets.info(Dispatch.hooks_table_name(), :size)
      rescue
        _ -> 0
      end

    Logger.info("[Hooks] Pipeline initialized with #{hook_count} hooks")
    {:ok, %{}}
  end

  @doc "Remove a dynamically-registered hook by event + name (synchronous)."
  def unregister(event, name) do
    GenServer.call(__MODULE__, {:unregister, event, name})
  end

  @impl true
  def handle_cast({:register, event, name, handler, priority, opts}, state) do
    Dispatch.insert(event, name, handler, priority, opts)
    {:noreply, state}
  end

  @impl true
  def handle_call({:unregister, event, name}, _from, state) do
    Dispatch.remove(event, name)
    {:reply, :ok, state}
  end

  # ── Registration helpers ───────────────────────────────────────────

  defp register_builtins do
    Enum.each(Handlers.builtins(), fn hook ->
      Dispatch.insert(
        hook.event,
        hook.name,
        hook.handler,
        Map.get(hook, :priority, 50),
        Map.get(hook, :opts, [])
      )
    end)
  end
end
