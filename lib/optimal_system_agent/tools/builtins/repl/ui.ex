defmodule OptimalSystemAgent.Tools.Builtins.REPL.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful execution; payload is output string
    * `:rejected`    — user denied permission
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"code" => code} = input, _opts) do
    %{
      kind: "repl",
      language: Map.get(input, "language", "python"),
      code_preview: String.slice(code, 0, 200)
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    %{
      kind: "repl_result",
      bytes: byte_size(content)
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "repl_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "repl_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
