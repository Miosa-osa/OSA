defmodule OptimalSystemAgent.Tools.Builtins.WebSearch do
  @moduledoc """
  Shim — delegates to the structured-layout implementation.

  All logic lives in `lib/optimal_system_agent/tools/builtins/web_search/`:
    * `web_search/tool.ex`      — `use OptimalSystemAgent.Tools.Behaviour`
    * `web_search/prompt.ex`    — dynamic prompt (includes current date)
    * `web_search/handler.ex`   — validate / check_permissions / execute
    * `web_search/ui.ex`        — Rust TUI render callbacks
    * `web_search/constants.ex` — exported atoms

  This module is kept so existing aliases (`WebSearch` short-form) continue to
  compile without modification. The registry resolves tools by name string, so
  both this shim and `WebSearch.Tool` resolve to `"web_search"`.
  """

  defdelegate name, to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate description, to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate parameters, to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate safety, to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate check_permissions(input, ctx), to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.WebSearch.Tool
end
