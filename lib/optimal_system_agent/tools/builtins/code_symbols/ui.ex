defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.UI do
  @moduledoc """
  Render maps for the Rust TUI.

  Stages:
    * `:tool_use`    — model called the tool, before result
    * `:tool_result` — successful extraction; payload is the symbol listing string
    * `:rejected`    — user denied permission
    * `:error`       — execution error
  """

  @spec render(atom(), any(), keyword()) :: map() | nil
  def render(:tool_use, %{"path" => path} = input, _opts) do
    %{
      kind: "code_symbols",
      path: path,
      type_filter: input["type"]
    }
  end

  def render(:tool_result, content, _opts) when is_binary(content) do
    symbol_count =
      content
      |> String.split("\n")
      |> Enum.count(&String.contains?(&1, "["))

    %{
      kind: "code_symbols_result",
      symbol_count: symbol_count
    }
  end

  def render(:rejected, _input, _opts) do
    %{kind: "code_symbols_rejected"}
  end

  def render(:error, msg, _opts) when is_binary(msg) do
    %{kind: "code_symbols_error", message: msg}
  end

  def render(_stage, _payload, _opts), do: nil
end
