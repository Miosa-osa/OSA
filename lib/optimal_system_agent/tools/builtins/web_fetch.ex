defmodule OptimalSystemAgent.Tools.Builtins.WebFetch do
  @moduledoc """
  Shim — delegates to the structured-layout implementation.

  All logic lives in `lib/optimal_system_agent/tools/builtins/web_fetch/`:
    * `web_fetch/tool.ex`      — `use OptimalSystemAgent.Tools.Behaviour`
    * `web_fetch/prompt.ex`    — dynamic prompt
    * `web_fetch/handler.ex`   — validate / check_permissions / execute
    * `web_fetch/ui.ex`        — Rust TUI render callbacks
    * `web_fetch/constants.ex` — exported atoms

  This module is kept so existing aliases (`WebFetch` short-form) continue to
  compile without modification. The registry resolves tools by name string, so
  both this shim and `WebFetch.Tool` resolve to `"web_fetch"`.
  """

  defdelegate name, to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate description, to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate parameters, to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate safety, to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate check_permissions(input, ctx), to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.WebFetch.Tool
end
