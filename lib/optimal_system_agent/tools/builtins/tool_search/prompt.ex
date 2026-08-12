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
  Fetches full schema definitions for deferred tools so they can be called.

  """

  @prompt_tail ~S"""
   Until fetched, only the name is known — there is no parameter schema, so the tool cannot be invoked. This tool takes a query, matches it against the deferred tool list, and returns the matched tools' complete JSONSchema definitions inside a <functions> block. Once a tool's schema appears in that result, it is callable exactly like any tool defined at the top of the prompt.

  Result format: each matched tool appears as one <function>{"description": "...", "name": "...", "parameters": {...}}</function> line inside the <functions> block — the same encoding as the tool list at the top of this prompt.

  Query forms:
  - "select:Read,Edit,Grep" — fetch these exact tools by name
  - "server:<name>" — list EVERY tool on one connected MCP server, unranked and uncapped
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
  @mcp_hint " MCP tools are listed separately, by server, in the <mcp-servers> block."

  defp tool_location_hint(:system_reminder),
    do: "Deferred tools appear by name in <system-reminder> messages." <> @mcp_hint

  defp tool_location_hint(:available_block),
    do: "Deferred tools appear by name in <available-deferred-tools> messages." <> @mcp_hint

  defp tool_location_hint(_),
    do: tool_location_hint(:system_reminder)
end
