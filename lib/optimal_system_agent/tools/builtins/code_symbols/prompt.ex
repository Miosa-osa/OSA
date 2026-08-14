defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Prompt do
  @moduledoc """
  Dynamic prompt for `code_symbols`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    """
    List functions, classes, and modules defined in a source file. `path` must be absolute.
    Languages: Elixir, Python, JavaScript/TypeScript, Go, Rust, Ruby, Java/Kotlin.
    For full file contents use `#{file_read_name}` instead.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
