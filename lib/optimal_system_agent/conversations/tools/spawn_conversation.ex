defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives under `lib/optimal_system_agent/conversations/tools/spawn_conversation/`:

    * `SpawnConversation.Tool`      — `use OptimalSystemAgent.Tools.Behaviour`, declarations
    * `SpawnConversation.Constants` — exported atoms for cross-tool reference
    * `SpawnConversation.Prompt`    — dynamic prompt builder
    * `SpawnConversation.Handler`   — validate / execute
    * `SpawnConversation.UI`        — render callbacks for the Rust TUI

  This module preserves the `OptimalSystemAgent.Conversations.Tools.SpawnConversation` atom
  so that existing registry entries, config references, and test aliases
  continue to resolve without modification.
  """

  @tool OptimalSystemAgent.Conversations.Tools.SpawnConversation.Tool

  defdelegate name, to: @tool
  defdelegate description, to: @tool
  defdelegate parameters, to: @tool
  defdelegate safety, to: @tool
  defdelegate available?, to: @tool
  defdelegate aliases, to: @tool
  defdelegate search_hint, to: @tool
  defdelegate prompt(opts), to: @tool
  defdelegate should_defer?, to: @tool
  defdelegate always_load?, to: @tool
  defdelegate concurrency_safe?(input, ctx), to: @tool
  defdelegate read_only?(input, ctx), to: @tool
  defdelegate destructive?(input, ctx), to: @tool
  defdelegate open_world?(input, ctx), to: @tool
  defdelegate max_result_size_chars, to: @tool
  defdelegate validate_input(input, ctx), to: @tool
  defdelegate check_permissions(input, ctx), to: @tool
  defdelegate execute(input, ctx), to: @tool
  defdelegate render(stage, payload, opts), to: @tool
  defdelegate to_classifier_input(input), to: @tool
end
