defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Produces structured maps consumed by the Rust-side `WebFetchRenderer`
  over the PubSub event channel. The Rust renderer (`priv/rust/tui/src/tools/web.rs`)
  parses `args` JSON for `url` and uses `result` as raw text — so `:tool_result`
  returns the content string directly rather than wrapping it in a map.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful fetch; payload is the content string
    * `:rejected`    — permission denied (URL blocked)
    * `:error`       — execution error
    * `:progress`    — unused for web_fetch (HTTP calls complete atomically)
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"url" => url} = input, _opts) do
    %{
      kind: "web_fetch",
      url: url,
      max_length: input["max_length"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "web_fetch_result",
      bytes: byte_size(content)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "web_fetch_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "web_fetch_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
