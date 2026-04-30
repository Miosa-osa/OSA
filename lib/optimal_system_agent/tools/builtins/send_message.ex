defmodule OptimalSystemAgent.Tools.Builtins.SendMessage do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  The registry and any callers that reference this module by the flat name
  continue to work unchanged. All implementation lives in:

      lib/optimal_system_agent/tools/builtins/send_message/
      ├── tool.ex
      ├── prompt.ex
      ├── handler.ex
      ├── ui.ex
      └── constants.ex
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate available?(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate strict?(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool

  defdelegate concurrency_safe?(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool

  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate interrupt_behavior(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate max_result_size_chars(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate deferred?(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate concurrent?(), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool

  defdelegate check_permissions(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool

  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool
  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.SendMessage.Tool

  @doc "Retrieve and clear pending messages for an agent. Called by react_loop."
  defdelegate drain_pending_messages(agent_id),
    to: OptimalSystemAgent.Tools.Builtins.SendMessage.Handler
end
