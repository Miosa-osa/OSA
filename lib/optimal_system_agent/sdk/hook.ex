defmodule OptimalSystemAgent.SDK.Hook do
  @moduledoc """
  Programmatic hook registration for the SDK.

  Thin wrapper around `Agent.Hooks.register/4` that provides a cleaner API
  for SDK consumers.

  ## Example

      OptimalSystemAgent.SDK.Hook.register(:pre_tool_use, "my_guard", fn payload ->
        if payload.tool_name == "shell_execute" do
          {:block, "Shell execution disabled"}
        else
          {:ok, payload}
        end
      end, priority: 5)
  """

  alias OptimalSystemAgent.Agent.Hooks

  @type hook_event :: Hooks.hook_event()
  @type hook_fn :: Hooks.hook_fn()

  @doc """
  Register a hook for an agent lifecycle event.

  ## Options
  - `:priority` — lower number runs first (default: 50)
  """
  @spec register(hook_event(), String.t(), hook_fn(), keyword()) :: :ok
  def register(event, name, handler, opts \\ []) do
    Hooks.register(event, name, handler, opts)
  end

  @doc "List all registered hooks."
  @spec list() :: map()
  def list do
    Hooks.list_hooks()
  end

  @doc "Get hook execution metrics."
  @spec metrics() :: map()
  def metrics do
    Hooks.metrics()
  end
end
