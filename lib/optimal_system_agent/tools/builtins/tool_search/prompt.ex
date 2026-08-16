defmodule OptimalSystemAgent.Tools.Builtins.ToolSearch.Prompt do
  @moduledoc """
  Dynamic prompt for `tool_search`.

  The prompt body is a
  function so it can adapt based on where deferred tools are announced:
  either in `<system-reminder>` messages (delta / lazy-loading path) or in
  a prepended `<available-deferred-tools>` block (legacy path).

  The three query forms in PROMPT_TAIL map exactly to `prompt.ts:49-51`:
    - "select:Read,Edit,Grep" — fetch exact tools by name
    - "notebook jupyter"      — keyword search, up to max_results matches
    - "+slack send"           — require first term in name, rank by rest
  """

  @prompt_head """
  Fetches the schemas of deferred tools so they can be called.

  """

  @prompt_tail ~S"""
   A deferred tool cannot be called until you fetch it here.

  Query forms:
  - "select:Read,Edit,Grep" — these exact tools by name
  - "server:<name>" — EVERY tool on one connected MCP server, unranked and uncapped
  - "notebook jupyter" — keyword search, up to max_results best matches
  - "+slack send" — require "slack" in the name, rank by remaining terms
  """

  @doc """
  Render the tool_search prompt.

  `opts` accepts:
    * `:deferred_location` — `:system_reminder` (default) | `:available_block`
      Controls the hint telling the model where deferred tool names appear.
  """
  @spec render(keyword()) :: String.t()
  def render(opts \\ []) do
    location = Keyword.get(opts, :deferred_location, :system_reminder)
    @prompt_head <> tool_location_hint(location) <> @prompt_tail
  end

  # Mirrors getToolLocationHint() at prompt.ts:35-42.
  # :system_reminder = delta/lazy-loading path (deferred tools appear in
  #   <system-reminder> attachments injected by the PromptAssembler).
  # :available_block = pre-gate legacy path (<available-deferred-tools>).
  #
  # BOTH hints now also point at <mcp-servers>. Deferred BUILTIN tools are the
  # only ones the PromptAssembler names in <system-reminder>; deferred MCP tools
  # are listed in the separate <mcp-servers> block built by
  # `Soul.ToolsSection.build_mcp_catalog/0`. Saying only "<system-reminder>"
  # told the model to look somewhere MCP tools have never appeared.
  @mcp_hint " MCP tools are listed by server in <mcp-servers>."

  defp tool_location_hint(:system_reminder),
    do: "Deferred tools are named in <system-reminder> messages." <> @mcp_hint

  defp tool_location_hint(:available_block),
    do: "Deferred tools are named in <available-deferred-tools> messages." <> @mcp_hint

  defp tool_location_hint(_),
    do: tool_location_hint(:system_reminder)
end
