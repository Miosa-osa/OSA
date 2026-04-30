defmodule OptimalSystemAgent.Tools.Builtins.WebSearch.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Produces structured maps consumed by the Rust-side `WebSearchRenderer`
  over the PubSub event channel. The Rust renderer (`priv/rust/tui/src/tools/web.rs`)
  parses `args` JSON for `query` and uses `result` as raw text — the renderer
  attempts JSON parsing of the result and falls back to plain text display.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful search; payload is the formatted results string
    * `:rejected`    — permission denied (unused — web_search always allows)
    * `:error`       — execution error (network failure, empty results, etc.)
    * `:progress`    — unused for web_search (HTTP calls complete atomically)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"query" => query} = input, _opts) do
    %{
      kind: "web_search",
      query: query,
      limit: input["limit"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "web_search_result",
      bytes: byte_size(content)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "web_search_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "web_search_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
