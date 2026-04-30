defmodule OptimalSystemAgent.Tools.Builtins.ListAgents.Prompt do
  @moduledoc """
  Dynamic prompt for `list_agents`.

  References `create_agent` and `delegate` by their live `Constants.tool_name/0`
  so a rename in either module propagates here automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    create_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.CreateAgent.Constants,
        :tool_name,
        "create_agent"
      )

    delegate_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.Delegate.Constants,
        :tool_name,
        "delegate"
      )

    """
    List all available agent roles and their capabilities.

    Use this to inspect the roster before delegating a complex task. Returns each
    agent's name, tier, description, blocked tools, and skill triggers.

    Usage:
    - Call with no arguments to see the full roster.
    - Pass `role` to get full detail (prompt preview, triggers) for a specific agent.
    - After reviewing the roster, use `#{delegate_name}` to dispatch work.
    - If the role you need doesn't exist, use `#{create_name}` to define it on the fly.
    - Agents not in the roster can still be delegated to — they run as generic subagents
      with full tool access and no specialised system prompt.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
