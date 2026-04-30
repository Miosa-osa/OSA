defmodule OptimalSystemAgent.Tools.Builtins.Download.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful download; payload is the result string
    * `:rejected`    — user denied permission (SSRF or blocked path)
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"url" => url, "path" => path}, _opts) do
    %{
      kind: "download",
      url: url,
      path: path
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "download_result",
      message: content
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "download_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "download_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
