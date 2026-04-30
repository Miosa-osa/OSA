defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent.Prompt do
  @moduledoc """
  Dynamic prompt for `create_agent`.

  References `list_agents` by its live `Constants.tool_name/0` so a rename
  propagates here automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    list_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.ListAgents.Constants,
        :tool_name,
        "list_agents"
      )

    delegate_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.Delegate.Constants,
        :tool_name,
        "delegate"
      )

    """
    Create a new specialized agent role that can be used with the `#{delegate_name}` tool.

    The agent definition is saved to ~/.osa/agents/ as an AGENT.md file and the
    `AgentRegistry` is immediately reloaded so the new role is available for delegation
    without restarting the session.

    Usage:
    - Use `#{list_name}` first to confirm the role doesn't already exist.
    - Provide a clear `instructions` system prompt describing the agent's approach,
      output format, and boundaries.
    - Set `tools_blocked` to restrict a read-only or scoped agent (e.g., `file_write,shell_execute`).
    - After creation the new role appears in `#{list_name}` output and can be delegated to
      immediately with `#{delegate_name}`.
    - Valid tiers: elite, specialist (default), utility.
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
