defmodule OptimalSystemAgent.Tools.Builtins.ToolSearch.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Mirrors the ToolSearchTool.ts `renderToolUseMessage` convention: the
  tool_use stage emits a compact render (query only); tool_result emits a
  count; other stages are nil (the TUI falls back to default rendering).

  The Claude Code reference returns `null` for `renderToolUseMessage` —
  we render a minimal struct instead so the TUI can show the query inline
  rather than silently skipping the event.
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"query" => query}, _opts) do
    %{kind: "tool_search", query: query}
  end

  def render(:tool_result, result, _opts) when is_binary(result) do
    # Extract match count from formatted result string (best-effort).
    count =
      case Regex.run(~r/^Found (\d+) tool/, result) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    %{kind: "tool_search_result", match_count: count}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "tool_search_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
